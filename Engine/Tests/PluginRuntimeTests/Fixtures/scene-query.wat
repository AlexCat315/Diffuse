(component
  (type $inspect-input (record (field "enabled" bool)))
  (type $query-interface (instance
    (export "query" (func (param "request" string) (result string)))
  ))
  (import (interface "cove:scene/query")
    (instance $scene-query (type $query-interface)))
  (alias export $scene-query "query" (func $query))

  (core module $libc
    (memory (export "memory") 1)
    (global $next (mut i32) (i32.const 4096))
    (func (export "realloc")
      (param $old i32) (param $old-size i32)
      (param $align i32) (param $new-size i32) (result i32)
      (local $result i32)
      local.get $new-size
      i32.eqz
      if (result i32)
        i32.const 0
      else
        global.get $next
        local.set $result
        global.get $next
        local.get $new-size
        i32.add
        global.set $next
        local.get $result
      end)
  )
  (core instance $libc (instantiate $libc))
  (core func $query-lower
    (canon lower (func $query)
      (memory $libc "memory")
      (realloc (func $libc "realloc"))))

  (core module $guest
    (import "libc" "memory" (memory 1))
    (import "host" "query" (func $query (param i32 i32 i32)))
    (data (i32.const 128) "{\22operation\22:\22snapshot\22}")

    (func (export "inspect") (param i32) (result i32)
      i32.const 128
      i32.const 24
      i32.const 0
      call $query
      i32.const 0)
  )
  (core instance $guest (instantiate $guest
    (with "libc" (instance $libc))
    (with "host" (instance (export "query" (func $query-lower))))
  ))
  (type $inspect-func (func
    (param "input" $inspect-input) (result string)))
  (func $inspect (type $inspect-func)
    (canon lift (core func $guest "inspect")
      (memory $libc "memory")
      (realloc (func $libc "realloc"))))
  (component $capabilities-component
    (type $local-input (record (field "enabled" bool)))
    (import "import-type-inspect-input"
      (type $import-input (eq $local-input)))
    (type $import-func (func
      (param "input" $import-input) (result string)))
    (import "import-func-inspect" (func $implementation
      (type $import-func)))
    (type $export-input (record (field "enabled" bool)))
    (export $public-input "inspect-input" (type $export-input))
    (type $export-func (func
      (param "input" $public-input) (result string)))
    (export "inspect" (func $implementation)
      (func (type $export-func))))
  (instance $capabilities
    (instantiate $capabilities-component
      (with "import-func-inspect" (func $inspect))
      (with "import-type-inspect-input" (type $inspect-input))))
  (export (interface "safe:reader/capabilities")
    (instance $capabilities))
)
