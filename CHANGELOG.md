# Changelog

Versioning complies with [semantic versioning (semver)](http://semver.org/).

<!-- RETAIN THIS COMMENT. An entry template for a new version is automatically added each time `Invoke-psake version` is called. Fill in changes afterwards. -->

* **v0.1.4** (2018-05-28):
  * [enhancement] Copying the empty string (i.e., effectively _clearing_ the clipboard) is now also supported in MTA threading mode (used in WinPSv2 by default, and optionally in WinPSv3+ if `powershell` is invoked with `-MTA`); thanks, @iricigor

* **v0.1.2** (2018-05-25):
  * [fix] Fix for [#2](https://github.com/mklement0/ClipboardText/issues/2); the module now also works in Windows PowerShell when invoked with `-MTA`.

* **v0.1.1** (2018-05-22):
  * Initial public release.
