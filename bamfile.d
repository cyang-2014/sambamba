module bamfile;

public import samheader;
public import reference;
public import alignment;
public import virtualoffset;
public import tagvalue;
import alignmentrange;
import bgzfrange;
import chunkinputstream;
import randomaccessmanager;
import bai.read;
import utils.range;

import std.stream;
import std.system;
import std.stdio;
import std.algorithm : map;
import std.range : zip;
import std.conv : to;
import std.exception : enforce;
import std.parallelism;
import std.array : uninitializedArray;

/**
  Represents BAM file
 */
struct BamFile {

    /**
      Constructor taking filename of BAM file to open,
      and optionally, task pool to use.
      
      Currently, opens the file read-only since library
      has no support for writing yet.
     */
    this(string filename, TaskPool task_pool = taskPool) {

        _filename = filename;
        _task_pool = task_pool;
        initializeStreams();
      
        try {
            _bai_file = BaiFile(filename);
            _random_access_manager = new RandomAccessManager(_filename, _bai_file);
        } catch (Exception e) {
            stderr.writeln("Couldn't find index file: ", e.msg);
            _random_access_manager = new RandomAccessManager(_filename);
        }

        auto magic = _bam.readString(4);
        
        enforce(magic == "BAM\1", "Invalid file format: expected BAM\\1");

        readSamHeader();
        readReferenceSequencesInfo();

        // right after constructing, we are at the beginning
        //                           of the list of alignments
    }
  
    /// True if associated BAI file was found
    bool has_index() @property {
        return _random_access_manager.found_index_file;
    }

    /*
       Get SAM header of file.
     */
    SamHeader header() @property {
        return _header;
    }

    /**
        Returns: information about reference sequences
     */
    ReferenceSequenceInfo[] reference_sequences() @property {
        return _reference_sequences;
    }

    /**
        Returns: range of alignments starting from the current file position.

        This is a single range of alignments which is affected by rewind() calls.

        The range operates on the file stream associated with this 
        BamFile instance. Therefore if you need to use more than one range
        simultaneously, create several BamFile instances. 
        However, that's not recommended because disk access performance 
        is better when the accesses are serial.
     */
    auto alignments() @property {
        if (_alignments_first_call) {
            _alignments_first_call = false;
            _alignment_range = alignmentRange(_decompressed_stream);
        }
        return _alignment_range;
    }
    private bool _alignments_first_call = true;

    /**
       Closes underlying file stream
     */
    void close() {
        _file.close();
    }
    
    /**
      Get an alignment at a given virtual offset.
     */
    Alignment getAlignmentAt(VirtualOffset offset) {
        return _random_access_manager.getAlignmentAt(offset);
    }


    /**
      Returns reference sequence with id $(D ref_id).
     */
    auto reference(int ref_id) {
        enforce(ref_id < _reference_sequences.length, "Invalid reference index");
        return ReferenceSequence(_random_access_manager, 
                                 ref_id,
                                 _reference_sequences[ref_id]);
    }

    /**
      Returns reference sequence named $(D ref_name).
     */
    auto opIndex(string ref_name) {
        enforce(ref_name in _reference_sequence_dict, "Invalid reference name");
        auto ref_id = _reference_sequence_dict[ref_name];
        return reference(ref_id);
    }

    /**
        Seeks to the beginning of the list of alignments.
        
        Effect: the range available through alignments() method
        is refreshed, and its front element is the first element
        in the file.
     */
    void rewind() {
        initializeStreams();
        _bam.readString(4); // skip magic
        int l_text;
        _bam.read(l_text);

        _bam.readString(l_text); // skip header 
        // TODO: there should be a faster way, without memory allocations

        int n_ref;
        _bam.read(n_ref);
        while (n_ref-- > 0) {
            int l_name;
            _bam.read(l_name);
            _bam.readString(l_name); // TODO: ditto
            int l_ref;
            _bam.read(l_ref);
        } // skip reference sequences information

        _alignment_range = alignmentRange(_decompressed_stream);
    }

private:
    
    string _filename;
    Stream _file;
    Stream _compressed_stream;
    BgzfRange _bgzf_range;
    IChunkInputStream _decompressed_stream;
    Stream _bam;

    BaiFile _bai_file; /// provides access to index file

    typeof(alignmentRange(_decompressed_stream)) _alignment_range;
    RandomAccessManager _random_access_manager;

    SamHeader _header;
    ReferenceSequenceInfo[] _reference_sequences;
    int[string] _reference_sequence_dict; /// name -> index mapping

    TaskPool _task_pool;

    // sets up the streams and ranges
    void initializeStreams() {
        
        _file = new BufferedFile(_filename);
        _compressed_stream = new EndianStream(_file, Endian.littleEndian);
        _bgzf_range = BgzfRange(_compressed_stream);

        version(serial) {
            auto chunk_range = map!decompressBgzfBlock(_bgzf_range);
        } else {
            /* TODO: tweak granularity */
//            auto chunk_range = parallelTransform!decompressBgzfBlock(_bgzf_range, 25);
            auto chunk_range = _task_pool.map!decompressBgzfBlock(_bgzf_range, 25);
        }
        
        _decompressed_stream = makeChunkInputStream(chunk_range);
        _bam = new EndianStream(_decompressed_stream, Endian.littleEndian); 
    }

    // initializes _header
    void readSamHeader() {
        int l_text;
        _bam.read(l_text);

        string text = to!string(_bam.readString(l_text));
        _header = SamHeader(text);
    }

    // initialize _reference_sequences
    void readReferenceSequencesInfo() {
        int n_ref;
        _bam.read(n_ref);
        _reference_sequences = new ReferenceSequenceInfo[n_ref];
        foreach (i; 0..n_ref) {
            _reference_sequences[i] = ReferenceSequenceInfo(_bam);

            // provide mapping Name -> Index
            _reference_sequence_dict[_reference_sequences[i].name] = i;
        }
    }
}
