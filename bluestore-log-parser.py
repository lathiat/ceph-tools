#!/usr/bin/python3

import sys
import os
import time
import datetime
import json
import re

_RE_OID = r'#(?P<pool_id>[\d]+):[0-9a-f]+:(?P<namespace>[^:]*)::(?P<oid>[^:]+):(?P<snap>[^:]*)#(?P<generation>[\S]*)'
_RE_HEX = r'[0-9a-fx]+'
_RE_OFFSET_LENGTH = r'(?P<offset_hex>[0-9a-fx]+)~(?P<len_hex>[0-9a-fx]+)'

def timestamp(x):
   xstamp = datetime.datetime.strptime(x, "%Y-%m-%d %H:%M:%S.%f")
   return xstamp

def isAligned(str, align):
  p = str.index("~")
  offset = int(str[:p], 16)
  len = int(str[p+1:], 16)
  end = offset + len
  if (offset % align == 0 and end % align == 0):
     return True
  else:
     return False

def main():
  filepath = sys.argv[1]
  if not os.path.isfile(filepath):
       print("File path {} does not exist. Exiting...".format(filepath))
       sys.exit()

  threads = {}
  with open(filepath) as fp:
    for origline in fp:
      try:
        m = re.match(r'^(?P<timestamp>[\d\-.: ]+) (?P<thread>[0-9A-Fa-f]+) (?P<loglevel>[\d]+) (?P<logger>[\S]+) (?P<line>.*)', origline)
        if not m:
           continue

        line = m.group('line')

        tls = threads.setdefault(m.group('thread'), {})
        linelog = tls.setdefault('lines', {})[origline.strip()] = []
        
        #print(m.groupdict())
        #2020-07-04 12:39:19.590177 7f92be2ac700 10 osd.160 771412 dequeue_op 0x55c7a60a12c0 prio 63 cost 4096 latency 0.001706 osd_op(client.90197393.0:151501437 17.170 17.75bb170 (undecoded) ondisk+write+known_if_redirected e771412) v8 pg pg[17.170( v 771412'73484964 (771412'73483424,771412'73484964] local-lis/les=754572/754573 n=18000 ec=272/272 lis/c 754572/754572 les/c/f 754573/754577/0 754572/754572/668118) [160,64,163] r=0 lpr=754572 luod=771412'73484963 lua=771412'73484963 crt=771412'73484964 lcod 771412'73484962 mlcod 771412'73484962 active+clean]
        dequeue = re.match(r'[\d]+ dequeue_op (?P<op_id>[\S]+) (?P<stage>finish|prio)( [\d]+ cost [\d]+ latency [\d.]+ (?P<op_data>.*)|)', m.group('line'))

        if dequeue:
          if dequeue.group('stage') == 'prio':
            if 'started' in tls:
              print(f"==== Exit #{m['thread']}")
              linestr = "\n    ".join(tls['lines'])
              print(json.dumps(tls, indent=4))
              print(f"==== Finish #{m['thread']}")
            del(threads[m.group('thread')])
            tls = threads.setdefault(m.group('thread'), {})
            linelog = tls.setdefault('lines', {})[origline.strip()] = []
            tls['started'] = True
          elif dequeue.group('stage') == 'finish':
            if 'started' in tls:
              print(f"==== Start #{m['thread']}")
              linestr = "\n    ".join(tls['lines'])
              print(json.dumps(tls, indent=4))
              print(f"==== Finish #{m['thread']}")
            del(threads[m.group('thread')])
            tls = threads.setdefault(m.group('thread'), {})
            linelog = tls.setdefault('lines', {})[origline.strip()] = []
          linelog.append(dequeue.groupdict())
        if 'started' not in tls:
          continue
        #_write 17.5d5_head #17:aba88e4f:::rbd_data.540609ac93f1da.0000000000001818:head# 0x316200~200 = 4096
        _REGEX_OP = fr'(?P<op_type>read|_write) (?P<pg_id>[\S]+) {_RE_OID} (?P<offset_hex>{_RE_HEX})~(?P<len_hex>{_RE_HEX})( = (?P<len_completed_dec>[\d]+))?'
        op = re.match(_REGEX_OP, line)
        if op:
          linelog.append(op.groupdict())
          if op.group('len_completed_dec') != None:
            tls['ops'][-1]['len_completed_dec'] = op.group('len_completed_dec')
          else:
            if 'ops' in tls:
              tls['ops'][-1]['has_subop'] = True
            tls.setdefault('ops', []).append(op.groupdict())
          #print(op.groupdict())

        #_do_write #17:d2244b5f:::rbd_data.194a556b8b4567.000000000000011d:head# 0x3c0400~4000 - have 0x400000 (4194304) bytes fadvise_flags 0x20
        _REGEX_DO_WRITE = fr'_do_write {_RE_OID} {_RE_OFFSET_LENGTH} - have (?P<have_len_hex>{_RE_HEX}) \((?P<have_len_dec>[\d]+)\) bytes fadvise_flags (?P<fadvise_flags>{_RE_HEX})'
        do_write = re.match(_REGEX_DO_WRITE, line)
        if do_write:
          linelog.append(do_write.groupdict())
          tls['ops'][-1]['do_write'] = do_write.groupdict()
          #print(do_write.groupdict())

        #_do_write_small 0x6576~9": []
        _REGEX_DO_WRITE_SMALL_A = fr'_do_write_small {_RE_OFFSET_LENGTH}'
        do_write_small_A = re.match(_REGEX_DO_WRITE_SMALL_A, line)
        if do_write_small_A:
          linelog.append(do_write_small_A.groupdict())
          tls['ops'][-1].setdefault('do_write_small', []).append(do_write_small_A.groupdict())

        #_do_write_small  reading head 0x576 and tail 0x0
        _REGEX_DO_WRITE_SMALL_B = fr'_do_write_small  reading head (?P<head_len>{_RE_HEX}) and tail (?P<tail_len>{_RE_HEX})'
        do_write_small_B = re.match(_REGEX_DO_WRITE_SMALL_B, line)
        if do_write_small_B:
          linelog.append(do_write_small_B.groupdict())
          #if tls['ops'][-1]['do_write_small']:
          tls['ops'][-1]['do_write_small'][-1].update(do_write_small_B.groupdict())

        #_do_write_small  write to unused 0x4000~1000 pad 0x0 + 0x0 of mutable Blob(0x5634799bbd50 blob([!~4000,0x74a208c000~4000] csum+has_unused crc32c/0x1000 unused=0xfff) use_tracker(0x2*0x4000 0x[0,2000]) SharedBlob(0x5634799bd790 sbid 0x0))
        #_do_write_small  deferred write 0xf000~1000 of mutable Blob(0x563401f61790 blob([!~c000,0x162438b0000~4000] csum+has_unused crc32c/0x1000 unused=0xfff) use_tracker(0x4*0x4000 0x[0,0,0,3000]) SharedBlob(0x56343cd3bf70 sbid 0x0)) at [0x162438b3000~1000]
        _REGEX_DO_WRITE_SMALL_C = fr'_do_write_small  (?P<small_write_type>write to unused|deferred write) {_RE_OFFSET_LENGTH}'
        do_write_small_C = re.match(_REGEX_DO_WRITE_SMALL_C, line)
        if do_write_small_C:
          linelog.append(do_write_small_C.groupdict())
          tls['ops'][-1]['do_write_small'][-1].update(do_write_small_C.groupdict())
          


        #_do_write_small  lex 0x6576~9: 0x6576~9 Blob(0x56346f687ab0 spanning 0 blob([0x192343a0000~4000,0x5bd1d91c000~4000] csum crc32c/0x1000) use_tracker(0x2*0x4000 0x[253f,1823]) SharedBlob(0x5634ba40c460 sbid 0x0))": [],

        #_do_read 0x0~16 size 0x16 (22)
        _REGEX_DO_READ = fr'_do_read {_RE_OFFSET_LENGTH} size (?P<object_size_hex>{_RE_HEX}) \((?P<object_size_dec>[\d]+)\)'
        do_read = re.match(_REGEX_DO_READ, line)
        if do_read:
          linelog.append(do_read.groupdict())
          tls['ops'][-1].setdefault('do_read', []).append(do_read.groupdict())
       
        #_do_read  blob Blob(0x56342362d250 blob([0x81eb46ec000~4000,0x5e743e14000~4000] csum crc32c/0x1000) use_tracker(0x2*0x4000 0x[4000,2400]) SharedBlob(0x56342362b5e0 sbid 0x0)) need 0x6000~200 cache has 0x[]
        #_do_read  blob Blob(0x5633f0146b50 blob([0x87d3a9c8000~4000,0x87da9b84000~4000,0x87dac5c0000~4000,0x1bac79f8000~4000] csum crc32c/0x1000) use_tracker(0x4*0x4000 0x[4000,4000,4000,4000]) SharedBlob(0x5633cdd3a0d0 sbid 0x0)) need 0x6000~600 cache has 0x[6000~600]
        #_do_read  blob Blob(0x56339265e4d0 blob([!~8000,0x8c97ad84000~4000] csum crc32c/0x1000) use_tracker(0x3*0x4000 0x[0,0,4000]) SharedBlob(0x56339265f340 sbid 0x0)) need 0x0x4b000:b000~1000
        #_do_read  blob Blob(0x56342362d250 blob([0x81eb46ec000~4000,0x5e743e14000~4000] csum crc32c/0x1000) use_tracker(0x2*0x4000 0x[4000,2400]) SharedBlob(0x56342362b5e0 sbid 0x0)) need 0x316000:6000~200
        #_do_read    region 0x316000: 0x6000~200 reading 0x6000~1000
        #https://www.regular-expressions.info/captureall.html
        _RE_BLOB = fr''
        _REGEX_DO_READ_BLOB = fr'_do_read  blob Blob\((?P<blob_id>{_RE_HEX})( spanning (?P<span_count>[\d]+))? blob\(\[{_RE_BLOB}\]'
      except:
        print(json.dumps(tls, indent=4))
        raise

if __name__ == '__main__':
   main()
