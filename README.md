This is a dump of various tools I hacked together to parse Ceph cluster data
looking for performance issues, mainly in scenarios where 90-95% of I/Os
complete in a reasonable time but 5-10% are taking extreme amounts of time
(multiple seconds)

These are quite rough and not really overly useful on their own, but may be
useful. You'll likely need to read the source to understand what they are
doing.

# ops_analyzer.rb

Processes the output of "dump_historic_ops" to measure the relative time spent
between various stages and output them in time order

# fstore_op_latency.rb

Processes the output of the OSD log with debug_osd=10 to determine the time
spent by the filestore_op thread processing each operation. Designed to
highlight when a small number of operations are taking a high amount of time
(e.g. 0.1 seconds or more) which can hold up the small number of filestore_op
threads.
