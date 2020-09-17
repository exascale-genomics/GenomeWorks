/*
* Copyright 2019-2020 NVIDIA CORPORATION.
*
* Licensed under the Apache License, Version 2.0 (the "License");
* you may not use this file except in compliance with the License.
* You may obtain a copy of the License at
*
*     http://www.apache.org/licenses/LICENSE-2.0
*
* Unless required by applicable law or agreed to in writing, software
* distributed under the License is distributed on an "AS IS" BASIS,
* WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
* See the License for the specific language governing permissions and
* limitations under the License.
*/
#include <claraparabricks/genomeworks/utils/pinned_host_vector.hpp>
#include <claraparabricks/genomeworks/utils/cudautils.hpp>
#include "ungapped_xdrop.cuh"
#include "ungapped_xdrop_kernels.cuh"
#include <thrust/scan.h>
#include <thrust/device_ptr.h>
#include <thrust/system/cuda/execution_policy.h>
#include <thrust/system/cpp/execution_policy.h>
#include <thrust/sort.h>
#include <thrust/unique.h>
#include <thrust/distance.h>
#include <thrust/device_vector.h>
#include <cub/device/device_select.cuh>
#include <chrono>

namespace claraparabricks
{

namespace genomeworks
{

namespace cudaextender
{

using namespace cudautils;

UngappedXDrop::UngappedXDrop(int32_t* h_sub_mat, int32_t sub_mat_dim, int32_t xdrop_threshold, bool no_entropy, cudaStream_t stream, int32_t device_id)
    : h_sub_mat_(h_sub_mat)
    , sub_mat_dim_(sub_mat_dim)
    , xdrop_threshold_(xdrop_threshold)
    , no_entropy_(no_entropy)
    , stream_(stream)
    , device_id_(device_id)
{
    // Calculate the max limits on the number of extensions we can do on
    // this GPU
    cudaDeviceProp device_prop;
    cudaGetDeviceProperties(&device_prop, device_id_);
    constexpr int32_t max_ungapped_per_gb   = 4194304; // FIXME: Calculate using sizeof datastructures
    constexpr int32_t max_seed_pairs_per_gb = 8388608; // FIXME: Calculate using sizeof datastructures
    const float global_mem_gb               = static_cast<float>(device_prop.totalGlobalMem) / 1073741824.0f;
    batch_max_ungapped_extensions_          = static_cast<int32_t>(global_mem_gb) * max_ungapped_per_gb;
    int32_t max_seed_pairs                  = static_cast<int32_t>(global_mem_gb) * max_seed_pairs_per_gb;
    // Switch to device for copying over initial structures
    scoped_device_switch dev(device_id_);

    // Allocate space on device for scoring matrix and
    GW_CU_CHECK_ERR(cudaMalloc((void**)&d_sub_mat_, sub_mat_dim_ * sizeof(int32_t)));
    // FIXME - Pinned host memory registration for proper async behavior
    device_copy_n(h_sub_mat_, sub_mat_dim_, d_sub_mat_, stream_);

    ScoredSegmentPair dummy_zero_pair = {{0, 0}, 0, 0};
    GW_CU_CHECK_ERR(cudaMalloc((void**)&d_done_, batch_max_ungapped_extensions_ * sizeof(int32_t)));
    GW_CU_CHECK_ERR(cudaMalloc((void**)&d_tmp_ssp_, batch_max_ungapped_extensions_ * sizeof(ScoredSegmentPair)));
    GW_CU_CHECK_ERR(cudaMemsetAsync((void*)d_done_, 0, batch_max_ungapped_extensions_ * sizeof(int32_t), stream_));
    GW_CU_CHECK_ERR(cudaMemsetAsync((void*)d_tmp_ssp_, 0, batch_max_ungapped_extensions_ * sizeof(ScoredSegmentPair), stream_));

    // Experimental cub usage
    // Get size of temporary storage
    int32_t* num_out;
    size_t temp_storage = 0;
    storage_ = 0;
    cub::DeviceSelect::Unique(NULL, temp_storage, d_tmp_ssp_, d_tmp_ssp_, num_out, batch_max_ungapped_extensions_);
    storage_ = std::max(temp_storage, storage_);
    std::cout<<"Storage requirement: "<< storage_<<std::endl;
    cub::DeviceScan::InclusiveSum(NULL,temp_storage, d_done_,d_done_+batch_max_ungapped_extensions_, batch_max_ungapped_extensions_);
    storage_ = std::max(temp_storage, storage_);
    std::cout<<"Storage requirement: "<< temp_storage<<std::endl;

    // Allocate temporary storage for cub
    GW_CU_CHECK_ERR(cudaMalloc((void**)&d_temp_storage_unique_, storage_));
    //TODO- Move out to device sample
    GW_CU_CHECK_ERR(cudaMalloc((void**)&d_num_hsps_temp, sizeof(int32_t)));


}

StatusType UngappedXDrop::extend_async(const char* d_query, int32_t query_length,
                                       const char* d_target, int32_t target_length,
                                       int32_t score_threshold, SeedPair* d_seed_pairs,
                                       int32_t num_seed_pairs, ScoredSegmentPair* d_scored_segment_pairs,
                                       int32_t& num_scored_segment_pairs)
{
    // Switch to configured GPU
    scoped_device_switch dev(device_id_);
    auto start1 = std::chrono::high_resolution_clock::now();
    int32_t curr_num_pairs      = 0;
    num_scored_segment_pairs    = 0;
    total_scored_segment_pairs_ = 0;
    for (int32_t seed_pair_start = 0; seed_pair_start < num_seed_pairs; seed_pair_start += batch_max_ungapped_extensions_)
    {
        curr_num_pairs = std::min(batch_max_ungapped_extensions_, num_seed_pairs - seed_pair_start);
        // TODO- Extricate the kernel launch params?
        find_high_scoring_segment_pairs<<<1024, 128, 0, stream_>>>(d_target,
                                                                   target_length,
                                                                   d_query,
                                                                   query_length,
                                                                   d_sub_mat_,
                                                                   no_entropy_,
                                                                   xdrop_threshold_,
                                                                   score_threshold,
                                                                   d_seed_pairs,
                                                                   curr_num_pairs,
                                                                   seed_pair_start,
                                                                   d_scored_segment_pairs,
                                                                   d_done_);
        // TODO- Make thrust use caching allocator or change kernel
        thrust::device_ptr<int32_t> d_done_dev_ptr(d_done_);
        //cudaStreamSynchronize(stream_);
        //auto start = std::chrono::high_resolution_clock::now();
        //thrust::inclusive_scan(thrust::cuda::par.on(stream_), d_done_dev_ptr, d_done_dev_ptr + curr_num_pairs, d_done_dev_ptr);
        cub::DeviceScan::InclusiveSum(d_temp_storage_unique_, storage_, d_done_, d_done_, curr_num_pairs, stream_);
        // TODO- Make async
        device_copy_n((d_done_ + curr_num_pairs - 1), 1, &num_scored_segment_pairs, stream_);
        cudaStreamSynchronize(stream_);
       // auto stop = std::chrono::high_resolution_clock::now();
        //auto duration = std::chrono::duration_cast<std::chrono::microseconds>(stop - start);
        //std::cout<<"Duration: "<<duration.count()<<" us"<<std::endl;

        if (num_scored_segment_pairs > 0)
        {
            compress_output<<<1024, 1024, 0, stream_>>>(d_done_,
                                                        seed_pair_start,
                                                        d_scored_segment_pairs,
                                                        d_tmp_ssp_,
                                                        curr_num_pairs); // TODO- Need configurability for kernel?
            thrust::device_ptr<ScoredSegmentPair> d_tmp_hsp_dev_ptr(d_tmp_ssp_);
            thrust::stable_sort(thrust::cuda::par.on(stream_),
                                d_tmp_hsp_dev_ptr,
                                d_tmp_hsp_dev_ptr + num_scored_segment_pairs,
                                scored_segment_pair_comp());
            thrust::device_ptr<ScoredSegmentPair> d_scored_segment_pairs_dev_ptr(d_scored_segment_pairs);

//            thrust::device_ptr<ScoredSegmentPair> result_end = thrust::unique_copy(thrust::cuda::par.on(stream_),
//                                                                                   d_tmp_hsp_dev_ptr,
//                                                                                   d_tmp_hsp_dev_ptr + num_scored_segment_pairs,
//                                                                                   d_scored_segment_pairs_dev_ptr + total_scored_segment_pairs_,
//                                                                                   scored_segment_pair_equal());
            cub::DeviceSelect::Unique(d_temp_storage_unique_,storage_, d_tmp_ssp_, d_scored_segment_pairs+total_scored_segment_pairs_, d_num_hsps_temp, num_scored_segment_pairs, stream_);
            num_scored_segment_pairs = get_value_from_device(d_num_hsps_temp, stream_);

            //num_scored_segment_pairs                         = thrust::distance(d_scored_segment_pairs_dev_ptr + total_scored_segment_pairs_, result_end);
            total_scored_segment_pairs_ += num_scored_segment_pairs;
        }
    }
    num_scored_segment_pairs = total_scored_segment_pairs_;
    auto stop1 = std::chrono::high_resolution_clock::now();
    auto duration = std::chrono::duration_cast<std::chrono::microseconds>(stop1 - start1);
    std::cout<<"Duration: "<<duration.count()<<" us"<<std::endl;
    return success;
}

const std::vector<ScoredSegmentPair>& UngappedXDrop::get_scored_segment_pairs() const
{
    std::vector<ScoredSegmentPair> placeholder;
    return placeholder;
}

StatusType UngappedXDrop::extend_async(const char* h_query, int32_t query_length,
                                       const char* h_target, int32_t target_length,
                                       int32_t score_threshold,
                                       std::vector<SeedPair>& h_seed_pairs)
{
    return success;
}

StatusType UngappedXDrop::sync()
{
    return success;
}

void UngappedXDrop::reset(){

};

UngappedXDrop::~UngappedXDrop()
{
    GW_CU_CHECK_ERR(cudaFree(d_sub_mat_));
    GW_CU_CHECK_ERR(cudaFree(d_tmp_ssp_));
    GW_CU_CHECK_ERR(cudaFree(d_done_));
};

} // namespace cudaextender

} // namespace genomeworks

} // namespace claraparabricks