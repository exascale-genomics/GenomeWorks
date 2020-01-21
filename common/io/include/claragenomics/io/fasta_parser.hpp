/*
* Copyright (c) 2020, NVIDIA CORPORATION.  All rights reserved.
*
* NVIDIA CORPORATION and its licensors retain all intellectual property
* and proprietary rights in and to this software, related documentation
* and any modifications thereto.  Any use, reproduction, disclosure or
* distribution of this software and related documentation without an express
* license agreement from NVIDIA CORPORATION is strictly prohibited.
*/
#pragma once

#include <string>
#include <memory>
#include <vector>

namespace claragenomics
{
namespace io
{

/// A structure to hold details of a single FASTA entry.
typedef struct
{
    /// Name of sequence.
    std::string name;
    /// Base pair representation of sequence.
    std::string seq;
} FastaSequence;

/// \class FastaParser
/// FASTA file parser
class FastaParser
{
public:
    /// \brief FastaParser implementations can have custom destructors, so delcare the abstract dtor as default.
    virtual ~FastaParser() = default;

    /// \brief Return number of sequences in FASTA file
    ///
    /// \return Sequence count in file
    virtual int32_t get_num_seqences() const = 0;

    /// \brief Fetch an entry from the FASTA file by index position in file.
    /// \param id Position of sequence in file. If id is greater than file size,
    ///           an error is thrown.
    ///
    /// \return A FastaSequence object describing the entry.
    virtual FastaSequence get_sequence_by_id(int32_t id) const = 0;

    virtual std::vector<std::pair<int,int>> get_read_chunks(int max_chunk_size = 1000000) const = 0;

};

/// \brief A builder function that returns a FASTA parser object which uses HTSLIB.
///
/// \param fasta_file Path to FASTA(.gz) file. If .gz, it must be zipped with bgzip.
///
/// \return A unique pointer to a constructed parser object.
std::unique_ptr<FastaParser> create_fasta_parser(const std::string& fasta_file);

/// \brief A builder function that returns a FASTA parser object which uses KSEQPP.
///
/// \param fasta_file Path to FASTA(.gz) file. If .gz, it must be zipped with bgzip.
///
/// \return A unique pointer to a constructed parser object.
std::shared_ptr<FastaParser> create_kseq_fasta_parser(const std::string &fasta_file);

} // namespace io
} // namespace claragenomics
