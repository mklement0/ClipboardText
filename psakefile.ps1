properties {
  #
}

task default -depends ShowTasks

task ShowTasks -description 'Lists all defined tasks.' {
  # !! Sadly, -docs use Format-* cmdlets behind the scenes, so you cannot
  # !! directly transform its output.
  (Invoke-psake -nologo -detailedDocs -notr | out-string -stream) | % { 
    $prop, $val = $_ -split ' *: '
    switch ($prop) {
      'Name' { $name = $val }
      'Description' {
        [pscustomobject] @{ Name = $name; Description = $val }
      }
    }
  } | Out-String | Write-Host -ForegroundColor Green
}

task Test -description 'Invokes Pester to run all tests.' {
  Invoke-Pester
}

