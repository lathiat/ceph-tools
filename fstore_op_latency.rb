#!/usr/bin/env ruby

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
            #printf("0%1s%1s%1s%1s %.6f %.6f %.6f %s", delta_w > threshold ? "W" : " ", delta_ws > threshold ? "S" : " ", delta_f > threshold ? "F" : "", partial ? "P" : " ", delta_w, delta_ws, delta_f, thread[thread_id][:start][:line])
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
