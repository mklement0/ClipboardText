# Changelog

Versioning complies with [semantic versioning (semver)](http://semver.org/).

<!-- RETAIN THIS COMMENT. An entry template for a new version is automatically added each time `Invoke-psake version` is called. Fill in changes afterwards. -->

* **v0.1.8** (2019-06-29):
  * [enhancement] For security and robustness, the standard shells and external clipboard programs are now invoked by full path (where known).

* **v0.1.7** (2018-10-08):
  * [fix] for #5: The prerequisites-check script now runs without error even when `Set-StrictMode -Version Latest` is in effect in the caller's scope.

* **v0.1.6** (2018-10-08):
  * [fix] for #4: A pointless warning is now no longer issued if `Set-ClipboardText` happens to be invoked while a UNC path is the current location (PSCore on Windows, WinPS v4-).

* **v0.1.5** (2018-09-14):
  * [enhancement] Implements #3. `Get-ClipboardText` now uses a helper type that is compiled on demand for accessing the clipboard via the Windows API, to avoid use of WSH, which may be blocked for security reasons.

* **v0.1.4** (2018-05-28):
  * [fix] With the exception of WinPSv5+ in STA mode (in wich case the built-in cmdlets are called), `clip.exe` (rather than `[System.Windows.Forms]`) is now used on Windows to avoid intermittent failures in MTA mode.
          Again, tip of the hat to @iricigor for encouraging me to use `clip.exe` consistently.

* **v0.1.3** (2018-05-28):
  * [enhancement] Copying the empty string (i.e., effectively _clearing_ the clipboard) is now also supported in MTA threading mode (used in WinPSv2 by default, and optionally in WinPSv3+ if `powershell` is invoked with `-MTA`); thanks, @iricigor

* **v0.1.2** (2018-05-25):
  * [fix] Fix for [#2](https://github.com/mklement0/ClipboardText/issues/2); the module now also works in Windows PowerShell when invoked with `-MTA`.

* **v0.1.1** (2018-05-22):
  * Initial public release.
