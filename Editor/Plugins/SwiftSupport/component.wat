(component
  (type $input (record (field "request" string)))
  (type $host-interface (instance
    (export "query" (func (param "request" string) (result string)))))
  (import (interface "guava:process/host") (instance $host (type $host-interface)))
  (alias export $host "query" (func $query))
  (core module $memory
    (memory (export "memory") 1)
    (global $next (mut i32) (i32.const 4096))
    (func (export "realloc") (param i32 i32 i32) (param $size i32) (result i32)
      (local $address i32)
      global.get $next
      local.tee $address
      local.get $size
      i32.add
      global.set $next
      global.get $next
      memory.size
      i32.const 16
      i32.shl
      i32.gt_u
      if
        global.get $next
        i32.const 65535
        i32.add
        i32.const 16
        i32.shr_u
        memory.size
        i32.sub
        memory.grow
        drop
      end
      local.get $address))
  (core instance $memory (instantiate $memory))
  (core func $query-lower
    (canon lower (func $query) (memory $memory "memory") (realloc (func $memory "realloc"))))
  (core module $guest
    (import "host" "query" (func $query (param i32 i32 i32)))
    (func (export "language-server") (param $pointer i32) (param $length i32) (result i32)
      local.get $pointer
      local.get $length
      i32.const 0
      call $query
      i32.const 0))
  (core instance $guest (instantiate $guest
    (with "host" (instance (export "query" (func $query-lower))))))
  (type $function (func (param "input" $input) (result string)))
  (func $run (type $function)
    (canon lift (core func $guest "language-server")
      (memory $memory "memory") (realloc (func $memory "realloc"))))
  (component $exports
    (type $local-input (record (field "request" string)))
    (import "input" (type $input (eq $local-input)))
    (type $function (func (param "input" $input) (result string)))
    (import "run" (func $run (type $function)))
    (type $public-input (record (field "request" string)))
    (export $input-type "language-server-input" (type $public-input))
    (type $export-function (func (param "input" $input-type) (result string)))
    (export "language-server" (func $run) (func (type $export-function))))
  (instance $exports (instantiate $exports (with "input" (type $input)) (with "run" (func $run))))
  (export (interface "studio:swift-support/capabilities") (instance $exports)))
