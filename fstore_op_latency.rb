#!/usr/bin/env ruby

# This script is designed to parse OSD logs with debug_filestore = 10 or 15 and
# calculate the latency of various parts of the process.
#
# It has two main purposes, the first is to count and calculate the latency of
# every operation, and secondly is to time specific parts of it with an
# original focus on the time spent inside the pwritev() call to the kernel,
# i.e. when we submit the I/O to the page cache.
#
# The reason I wanted to catch this is that if a write is made that is not
# wholly formed of entire 4K pages, then the kernel may need to fetch the rest
# of that 4K from the disk as it cannot buffer the write in memory of only part
# of a page. In this case the pwritev() call which is normally a buffered write
# then BLOCKS waiting for the rest of the page to come back from disk. This
# holds up your filestore_op_thread of which by default there are only 2,
# possibly for 100s of milliseconds in a HDD environment.
#
# In that particular environment the fix for this problem, because they had
# a high percentage of what I call 'Partial' writes (that is writes that are
# not 4K aligned and also sized in multiples of 4K) due to having primarily
# Windows clients which generally align writes to 512b and not 4k unlike Linux
# clients which almost exclusively send 4k I/Os because that is the granularity
# of the page cache (at least where PAGE_SIZE is 4k anyway.. usually the case..
# for now..)
#
# The fix for that particular environment was to set filestore_fadvise=false..
# the problem was that Ceph helpfully tells the kernel to throw away the page
# cache for objects on secondary OSDs because it doesn't expect to read from it
# again. But doesn't account for needing the rest of the page to complete
# a partial write in the future. This is problematic on it's own but
# particularly problematic when you have a fast NVMe journal but slower HDD
# OSD.

# Author: Trent Lloyd
# https://github.com/lathiat/ceph-tools
# License: GPL v3

require 'pp'
require 'date'

partial_ops = 0
slow_ops = 0
slow_partial_ops = 0
slow_ops_time = 0
total_ops = 0
thread = {}

partial_sizes = {}
threshold = 0.2

ARGF.each_line do |l|
    a = l.split(" ")
    begin
        cur_t = DateTime.parse(a[0..1].join(" ")).to_time
    rescue ArgumentError
        next
    end
    thread_id = a[2]
    next if cur_t.nil?
    if l =~ / _do_op .* start$/
        thread[thread_id] = {start: {time: cur_t, line: l}}
    end
    if l =~ / 10 filestore(.*) write .*/
        next unless thread[thread_id]
        write_data = a[7].split("~")
        wr_offset = write_data[0].to_i
        wr_size = write_data[1].to_i
        start_partial = (wr_offset % 4096)
        end_partial = ((wr_offset + wr_size) % 4096)
        start_block = wr_offset / 4096
        end_block = (wr_offset + wr_size) / 4096
        num_blocks = end_block - start_block + 1
        if num_blocks == 1
            if (start_partial > 0) && (end_partial > 0)
                end_partial = 0
            end
        end
        if start_partial > 0
            partial_sizes[start_partial] ||= 0
            partial_sizes[start_partial] += 1
        end
        if end_partial > 0
            partial_sizes[end_partial] ||= 0
            partial_sizes[end_partial] += 1
        end
        thread[thread_id][:write] = {time: cur_t, line: l, start_partial: start_partial, end_partial: end_partial}
    end
    if l =~ / 15 filestore(.*) write .*/
        next unless thread[thread_id]
        thread[thread_id][:write_start] = {time: cur_t, line: l}
    end
    if l=~ /_do_op .*, finisher/
        next unless thread[thread_id]
        next unless thread[thread_id][:write]
        next unless thread[thread_id][:start]
        total_ops += 1
        thread[thread_id][:finish] = {time: cur_t, line: l}
        delta_w = thread[thread_id][:write][:time] - thread[thread_id][:start][:time]
        delta_f = thread[thread_id][:finish][:time] - thread[thread_id][:write][:time]
        if thread[thread_id][:write_start]
            delta_ws = thread[thread_id][:write][:time] - thread[thread_id][:write_start][:time]
        else
            delta_ws = 0.000000
        end

        partial = false
        if thread[thread_id][:write][:start_partial] > 0 || thread[thread_id][:write][:end_partial] > 0
            partial = true
            partial_ops += 1
            #printf("0%1s%1s%1s%1s %.6f %.6f %.6f %s", delta_w > threshold ? "W" : " ", delta_ws > threshold ? "S" : " ", delta_f > threshold ? "F" : "", partial ? "P" : " ", delta_w, delta_ws, delta_f, thread[thread_id][:write][:line])
        end
        if delta_w > threshold || delta_f > threshold || delta_ws > threshold
            slow_ops += 1
            slow_ops_time += delta_w
            slow_ops_time += delta_f
            slow_partial_ops += 1 if partial
            printf("1%1s%1s%1s%1s %.6f %.6f %.6f %s", delta_w > threshold ? "W" : " ", delta_ws > threshold ? "S" : " ", delta_f > threshold ? "F" : "", partial ? "P" : " ", delta_w, delta_ws, delta_f, thread[thread_id][:start][:line])
            printf("2%1s%1s%1s%1s %.6f %.6f %.6f %s", delta_w > threshold ? "W" : " ", delta_ws > threshold ? "S" : " ", delta_f > threshold ? "F" : "", partial ? "P" : " ", delta_w, delta_ws, delta_f, thread[thread_id][:write][:line])
            printf("3%1s%1s%1s%1s %.6f %.6f %.6f %s", delta_w > threshold ? "W" : " ", delta_ws > threshold ? "S" : " ", delta_f > threshold ? "F" : "", partial ? "P" : " ", delta_w, delta_ws, delta_f, thread[thread_id][:finish][:line])
            printf("\n")
        end
    end
end

printf("%8s: %d\n", "Slow Ops", slow_ops)
printf("%8s: %d\n", "Partial (non-4K) Ops", partial_ops)
printf("%8s: %d\n", "Slow & Partial Ops", slow_partial_ops)
printf("%8s: %d\n", "Total Ops", total_ops)
printf("%8s: %d\n", "Slow Ops Time", slow_ops_time)
pp partial_sizes
