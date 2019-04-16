#!/usr/bin/env ruby
#
# Author: Trent Lloyd
# https://github.com/lathiat/ceph-tools
# License: GPL v3

require 'pp'
require 'json'
require 'date'

input_fn = ARGV[0]
input_file = open(input_fn)
j = JSON.parse(input_file.read)
ops = {}

if j["ops"]
    op_in = j["ops"]
else
    op_in = j["Ops"]
end

measure_between = {"reached_pg" => ["journaled_completion_queued"],
                   "initiated" => ["commit_sent", "journaled_completion_queued", "reached_pg", "op_commit"],
                   "started" => ["commit_queued_for_journal_write"],
                   "commit_queued_for_journal_write" => ["journaled_completion_queued", "op_commit"],
}
interesting = []

op_in.each do |op|
    key = op["description"]
    raise if ops[key]
    ops[key] = {}
    ops[key][:op] = op
    state, client, steps = op["type_data"]

    times = {}
    initiated_t = DateTime.parse(op["initiated_at"]).to_time
    next if steps.nil?

    measures = {}
    last_step = {"time" => op["initiated_at"], "event" => "start"}
    last_step_t = DateTime.parse(op["initiated_at"]).to_time
    step_to_time = {}
    steps.each do |step|
        step_t = DateTime.parse(step["time"]).to_time
        step_to_time[step["event"]] = DateTime.parse(step["time"]).to_time
        delta_t = step_t - last_step_t
        key = "#{last_step["event"]}-#{step["event"]}"
        times[key] = delta_t unless times[key]
        last_step = step
        last_step_t = step_t
    end

    measure_between.each do |start_event_name, end_event_names|
        start_event = step_to_time[start_event_name]
        end_event_names.each do |end_event_name|
            end_event = step_to_time[end_event_name]
            if start_event and end_event
                times["#{start_event_name}-#{end_event_name}"] = end_event - start_event
            end
        end
    end

    # We are looking for local operations.. if it takes >0.1s to get to
    # reached_pg then the issue is likely rw locks. If it takes less than 0.5
    # seconds to get to op_commit then it is a 'relatively' fast operation
    # (still slower than desired)
    #next if times["initiated-reached_pg"] > 0.5
    if times["initiated-op_commit"]
      next if times["initiated-op_commit"] < 0.3
    end
    next if times["waiting for rw locks-reached_pg"]


    print "-----\n"
    pp op
    pp times.to_a.sort{|b, a| a[1] <=> b[1] }
    #if times["until journaled_completion_queued"].to_f > 1 and times["until reached_pg"].to_f < 1
    #end
end
