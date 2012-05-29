module bai.bin;

import bai.chunk;

/// Distinct bin
struct Bin {
    uint id; /// bin number
    Chunk[] chunks; 

    /// How deep the bin is in the tree
    int level() @property {
        if (id == 0) return 0;
        if (id < 9) return 1;
        if (id < 73) return 2;
        if (id < 585) return 3;
        if (id < 4681) return 4;
        return 5;
    }

	/// Check if bin can overlap with a region
	bool canOverlapWith(int begin, int end) {
		if (id == 0) return true;

		/// The following code is based on reg2bins() function
		auto magic_number = 4681;
		auto b = begin >> 14;
		auto e = end   >> 14;
		
		while (true) {
			auto delta = id - magic_number;
			if (b <= delta && delta <= e) return true;

			magic_number >>= 3;

			if (magic_number == 0) return false;

			b >>= 3;
			e >>= 3;
		}
	}
}

