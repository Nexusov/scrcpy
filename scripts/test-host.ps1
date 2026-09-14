param([string]$SuitePath, [string]$ReadyEvent, [string]$ArchivePath)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
$startupGateTimeoutMilliseconds = 10000
$ready = [Threading.EventWaitHandle]::OpenExisting($ReadyEvent)

try {

    if (-not $ready.WaitOne($startupGateTimeoutMilliseconds)) {
        throw 'The runner did not attach this test to its process job.'
    }
} finally {
    $ready.Dispose()
}

if ($ArchivePath) {
    . $SuitePath -ArchivePath $ArchivePath
    $succeeded = $?
} else {
    . $SuitePath
    $succeeded = $?
}

if (-not $succeeded) {

    if ($LASTEXITCODE) {
        exit $LASTEXITCODE
    }

    exit 1
}
