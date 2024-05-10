@echo off

cls

set ROOT_DIR=%cd%
if not exist _build mkdir _build

pushd _build
	odin run %ROOT_DIR%
popd
