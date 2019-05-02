module qpimem_cache #(
	//Simple 2-way cache.
	parameter integer CACHELINE_WORDS=4,
	parameter integer CACHELINE_CT=32,
	parameter integer ADDR_WIDTH=21 //addresses words
	//Cache size is CACHELINE_WORDS*CACHELINE_CT*4 bytes.
) (
	input clk,
	input rst,
	
	output reg qpi_do_read,
	output reg qpi_do_write,
	input qpi_next_byte,
	output reg [ADDR_WIDTH+2-1:0] qpi_addr, //note: this addresses bytes
	output reg [31:0] qpi_wdata,
	input [31:0] qpi_rdata,
	input qpi_is_idle,

	input [ADDR_WIDTH-1:0] addr,
	input [3:0] wen,
	input ren,
	input [31:0] wdata,
	output [31:0] rdata,
	output reg ready
);

/*
Recap of cache theory: 
The cache itself is a memory consisting of x cache lines. These cache lines are
split in (here) 2 ways. Each pair of 2 cache lines with the same address is called
a cache set. Each line in the cache set has data memory of a bunch of words, as well
as tag and flag memory.

For the cache, an address is divided in three components:
addr = {tag, set, offset}
The set bit refers to a specific set of (2 here) cache lines, the offset is an offset
into these lines. The specific line that is used depends on the tag: the line where
the contents of its tag memory equals the tag bit of the address will be used. If there's
no match, there's a cache miss.

On a cache miss, one of the two lines needs to be flushed (written back to main memory)
if it's dirty (written to after read from memory). It then needs to be reloaded from the
bit of memory that contains the requested address, and its tag memory and flags updated.
After that, we can retry and the cache will hit.

The strategy to decide which cache line will be reloaded is LRU, or Least Recently Used.
Every read from or write to a cache line, the cache will store a flag in the flag memory
of the set indicating that that specific way of cache is used most recently, and thus
the other line should be choosen for flush/reload if needed.
*/


//note: do not change, there's no logic for anything but a 2-way LRU cache.
parameter integer CACHE_WAYS=2;

//Remember: address = {tag, set, offset}
parameter CACHE_SETS=CACHELINE_CT/CACHE_WAYS;
parameter CACHE_TAG_BITS=ADDR_WIDTH-$clog2(CACHELINE_WORDS*CACHE_SETS);
parameter CACHE_SET_BITS=$clog2(CACHE_SETS);
parameter CACHE_OFFSET_BITS=$clog2(CACHELINE_WORDS);

//Easy accessor macros
`define TAG_FROM_ADDR(addr) addr[ADDR_WIDTH-1:ADDR_WIDTH-CACHE_TAG_BITS]
`define SET_FROM_ADDR(addr) addr[CACHE_OFFSET_BITS+CACHE_SET_BITS-1:CACHE_OFFSET_BITS]
`define OFFSET_FROM_ADDR(addr) addr[CACHE_OFFSET_BITS-1:0]
`define CACHEDATA_ADDR(way, set, offset) (way*CACHE_SETS*CACHELINE_WORDS+set*CACHELINE_WORDS+offset)

//Bits in flag memory
parameter integer FLAG_LRU=0;
parameter integer FLAG_CW1_CLEAN=1;
parameter integer FLAG_CW2_CLEAN=2;

reg [3:0] cachedata_wen;
reg [31:0] cachedata_wdata;
wire [31:0] cachedata_rdata;
reg [CACHE_SET_BITS+CACHE_OFFSET_BITS:0] cachedata_addr;

//Cache memory, tag memory, flags memory.
simple_mem_words #(
	.WORDS(CACHELINE_CT*CACHELINE_WORDS),
`ifdef verilator
	.INITIAL_HEX("rom.hex")
`else
	.INITIAL_HEX("rom_random_seeds0x123456.hex")
`endif
) cachedata (
	.clk(clk),
	.wen(cachedata_wen),
	.addr(cachedata_addr),
	.wdata(cachedata_wdata),
	.rdata(cachedata_rdata)
);

assign rdata = cachedata_rdata;
wire [CACHE_TAG_BITS-1:0] tag_wdata;
wire [CACHE_TAG_BITS-1:0] tag_rdata[0:1];
reg [1:0] tag_wen;

genvar i;
for (i=0; i<2; i=i+1) begin
	simple_mem #(
		.WORDS(CACHE_SETS),
		.WIDTH(CACHE_TAG_BITS),
		//Cache maps to first block of memory.
		.INITIAL_FILL(i) //*10 is random: we want only the first 8K for simulation as the app is in the 2nd.
	) tagdata (
		.clk(clk),
		.wen(tag_wen[i]),
		.addr(`SET_FROM_ADDR(addr)),
		.wdata(`TAG_FROM_ADDR(addr)),
		.rdata(tag_rdata[i])
	);
end

reg flag_wen;
reg [2:0] flag_wdata;
wire [2:0] flag_rdata;

simple_mem #(
	.WORDS(CACHE_SETS),
	.WIDTH(4),
	.INITIAL_FILL('b0)
) flagdata (
	.clk(clk),
	.wen(flag_wen),
	.addr(`SET_FROM_ADDR(addr)),
	.wdata(flag_wdata),
	.rdata(flag_rdata)
);

wire [CACHE_SET_BITS-1:0] current_set;
assign current_set = `SET_FROM_ADDR(addr);

//Find the cache line the current address is located in.
reg cachehit_way;
reg found_tag; //this being 0 indicates a cache miss
wire doing_cache_refill;
reg [CACHE_OFFSET_BITS-1:0] cache_refill_offset;
reg [3:0] cache_refill_wen;
reg cache_refill_flag_wen;
always @(*) begin
	found_tag=0;
	cachehit_way=0;
	qpi_wdata = cachedata_rdata;
	flag_wdata = flag_rdata;
	flag_wen = 0;
	if (tag_rdata[0]==`TAG_FROM_ADDR(addr)) begin
		found_tag=1;
		cachehit_way=0; //DO U KNOW THE WAY
		flag_wdata[FLAG_CW1_CLEAN] = flag_rdata[FLAG_CW1_CLEAN] && (wen == 0);
		flag_wdata[FLAG_CW2_CLEAN] = flag_rdata[FLAG_CW2_CLEAN];
		flag_wdata[FLAG_LRU]=1;
		flag_wen = 1;
	end else if (tag_rdata[1]==`TAG_FROM_ADDR(addr)) begin
		found_tag=1;
		cachehit_way=1;
		flag_wdata[FLAG_CW1_CLEAN] = flag_rdata[FLAG_CW1_CLEAN];
		flag_wdata[FLAG_CW2_CLEAN] = flag_rdata[FLAG_CW2_CLEAN] && (wen == 0);
		flag_wdata[FLAG_LRU]=0;
		flag_wen = 1;
	end
	if (found_tag && !doing_cache_refill) begin
		//Tag is found. Route the read or write to the cache data store
		cachedata_addr = `CACHEDATA_ADDR(cachehit_way, `SET_FROM_ADDR(addr), `OFFSET_FROM_ADDR(addr));
		cachedata_wen = wen;
		cachedata_wdata = wdata;
	end else begin
		//No tag. Switch over control of cache data to refill logic.
		cachedata_addr = `CACHEDATA_ADDR(flag_rdata[FLAG_LRU], `SET_FROM_ADDR(addr), cache_refill_offset);
		//A cache line reload will always un-dirty the LRU page. Prepare the flags that indicate it so the
		//reload state machine only has to write them.
		flag_wdata[FLAG_CW1_CLEAN] = (flag_rdata[FLAG_LRU]==0) ? 1 : flag_rdata[FLAG_CW1_CLEAN];
		flag_wdata[FLAG_CW2_CLEAN] = (flag_rdata[FLAG_LRU]==1) ? 1 : flag_rdata[FLAG_CW2_CLEAN];
		flag_wdata[FLAG_LRU] = flag_rdata[FLAG_LRU]; //doesn't matter actually
		flag_wen = cache_refill_flag_wen;
		cachedata_wdata = qpi_rdata;
		cachedata_wen = cache_refill_wen;
	end
end


wire need_cache_refill;
wire cache_line_lru;
wire cache_line_lru_clean;
//Assumption: ren/wen/addr will stay stable until we have signaled the memory is ready.
assign need_cache_refill = !found_tag && (ren || wen!=0);
assign cache_line_lru = flag_rdata[FLAG_LRU];
assign cache_line_lru_clean = cache_line_lru ? 
		flag_rdata[FLAG_CW2_CLEAN] : 
		flag_rdata[FLAG_CW1_CLEAN];

reg [CACHE_OFFSET_BITS-1:0] write_words_left;

assign doing_cache_refill = qpi_do_read || qpi_do_write;

always @(posedge clk) begin
	if (rst) begin
		qpi_do_read <= 0;
		qpi_do_write <= 0;
		qpi_addr <= 0;
		ready <= 0;
		cache_refill_flag_wen <= 0;
		tag_wen <= 0;
		cache_refill_offset <= 0;
		write_words_left <= 0;
		cache_refill_wen <= 0;
	end else begin
		ready <= 0;
		cache_refill_flag_wen <= 0;
		tag_wen[0] <= 0;
		tag_wen[1] <= 0;
		cache_refill_wen <= 0;
		if (found_tag && (ren || wen!=0) && !doing_cache_refill) begin
			//Cache hit
			ready <= 1;
		end else if (!need_cache_refill) begin
			//Nothing going on. Idle.
		end else if (!qpi_do_read && !qpi_do_write && !qpi_is_idle) begin
			//Done reading/writing, but we have to wait for the qpi iface to get idle again.
		end else if (need_cache_refill) begin
			//Tag not found! Grabbing from SPI memory.
			if (!qpi_do_read && !qpi_do_write) begin
				//Start. See if we need to do writeback
				if (!cache_line_lru_clean) begin
					qpi_do_write <= 1;
					//Address is the address that the LRU has
					qpi_addr[23:2+CACHE_OFFSET_BITS] <= {cache_line_lru?tag_rdata[1]:tag_rdata[0], current_set};
					qpi_addr[2+CACHE_OFFSET_BITS-1:0] <= 0;
					write_words_left <= 'hffff; //all ones
					cache_refill_offset <= 0;
					//note: qpi memory always writes what's read from cachedata mem.
				end else begin
					qpi_do_read <= 1;
					//Read from the address the user gave
					qpi_addr[23:2+CACHE_OFFSET_BITS] <= {`TAG_FROM_ADDR(addr), current_set};
					qpi_addr[2+CACHE_OFFSET_BITS-1:0] <= 0;
					cache_refill_offset <= -1;
					//note: on refill, cache always writes whatever comes from cachedata mem.
				end
			end else if (qpi_do_write && qpi_next_byte) begin
				qpi_addr[2+CACHE_OFFSET_BITS-1:2] <= qpi_addr[2+CACHE_OFFSET_BITS-1:2] + 1;
				cache_refill_offset <= cache_refill_offset + 1;
				write_words_left <= write_words_left - 1;
				if ((write_words_left)==1) begin
					//last write of the cache line, mark cache line clean
					//Note that because we cleaned the cache line but there's still no cache hit,
					//the next round (after the qspi machine has gone idle), we'll do the actual
					//read of the cache line.
					qpi_do_write <= 0;
					//Un-dirtied flags are already prepared in the combinatorial logic; we just need to
					//write it.
					cache_refill_flag_wen <= 1;
				end
			end else if (qpi_do_read && qpi_next_byte) begin
				qpi_addr[2+CACHE_OFFSET_BITS-1:2] <= qpi_addr[2+CACHE_OFFSET_BITS-1:2] + 1;
				cache_refill_offset <= cache_refill_offset + 1;
				cache_refill_wen <= 'hf;
				if (&qpi_addr[2+CACHE_OFFSET_BITS-1:2]) begin
					if (cache_line_lru == 0) begin
						tag_wen[0] <= 1;
					end else begin
						tag_wen[1] <= 1;
					end
					qpi_do_read <= 0;
				end
			end
		end
	end
end

endmodule