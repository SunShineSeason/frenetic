monitor_tbl
 (1, (if vlan = <none> then (if * then 5000 else drop | if ! <none> then all else drop) else drop);
      vlan <none> -> 1)