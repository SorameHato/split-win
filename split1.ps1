# split-win
# https://github.com/anseki/split-win
#
# Copyright (c) 2015 anseki
# Licensed under the MIT license.

Param(
  [Parameter(Mandatory=$True)] [string] $path,
  [long] $size = 256mb, # split size 256mb
  [switch] $noJoin = $False,
  [switch] $noTest = $False,
  [switch] $noSum = $False
)

[long] $BUFFER_BYTES = 1024 * 80

if (-not (Test-Path $path)) {
  $Host.UI.WriteErrorLine('Specify a target file.')
  exit 1
}

'Target File: {0} ({1:#,0} bytes)' -f $path, $(Get-ChildItem $path).Length

[long] $srcBytes = $(Get-ChildItem $path).Length

if ($srcBytes -le $size) {
  $Host.UI.WriteErrorLine(
    'Specify a file larger than {0:#,0} bytes.' -f $size
  )
  exit 1
}

$path = $(Get-ChildItem $path).FullName

[IO.FileStream] $streamSrc = New-Object IO.FileStream(
  $path,
  [IO.FileMode]::Open,
  [IO.FileAccess]::Read
)

[Collections.Generic.List[string]] $destList =
  New-Object Collections.Generic.List[string]

[int] $fileNum = 0
[IO.FileStream] $streamDest
[long] $destBytes = 0
[long] $readBytes = -1

while ($srcBytes -gt 0 -and $readBytes -ne 0) {

  if ($destBytes -ge $size -or $streamDest -eq $Null) {

    if ($streamDest -ne $Null) {
      $streamDest.Close()
      $destList.Add($pathDest)

      'Saved File: {0}' -f (Split-Path $pathDest -Leaf)
    }

    # New file
    $fileNum++

    [string] $pathDest =
      $path + '.' + $fileNum.ToString('000')

    $streamDest = New-Object IO.FileStream(
      $pathDest,
      [IO.FileMode]::Create,
      [IO.FileAccess]::Write
    )

    $destBytes = 0
  }

  [long] $copyBytes = $BUFFER_BYTES

  if ($copyBytes -gt $srcBytes) {
    $copyBytes = $srcBytes
  }

  if ($copyBytes -gt ($size - $destBytes)) {
    $copyBytes = $size - $destBytes
  }

  [byte[]] $data = New-Object byte[] $copyBytes

  $readBytes =
    $streamSrc.Read($data, 0, $copyBytes)

  $streamDest.Write(
    $data,
    0,
    $readBytes
  )

  $srcBytes -= $readBytes
  $destBytes += $readBytes
}

if ($streamDest -ne $Null -and $destBytes -gt 0) {

  $streamDest.Close()
  $destList.Add($pathDest)

  'Saved File: {0}' -f (Split-Path $pathDest -Leaf)
}

$streamSrc.Close()


# ============================================================
# File names
# ============================================================

[string] $baseName =
  Split-Path $path -Leaf

[string] $baseDir =
  Split-Path $path -Parent


# ============================================================
# Join command
# ============================================================

[string] $cmdJoin =
  'COPY /b ' +
  [string]::Join(
    '+',
    ($destList | ForEach-Object {
      '"%~dp0' + (Split-Path $_ -Leaf) + '"'
    })
  )


# ============================================================
# Join BAT
# ============================================================

if (-not $noJoin) {

  Out-File `
    -FilePath ($path + '.join.bat') `
    -Encoding Default `
    -InputObject (
      "@echo off`r`n" +
      $cmdJoin +
      ' "%~dp0' +
      $baseName +
      '"'
    )
}


# ============================================================
# Join test BAT
# ============================================================

if (-not $noTest) {

  Out-File `
    -FilePath ($path + '.join.test.bat') `
    -Encoding Default `
    -InputObject (

      "@echo off`r`n" +

      $cmdJoin +
      ' "%~dp0' +
      $baseName +
      '.tmp"' +
      "`r`n" +

      'fc /b "%~dp0' +
      $baseName +
      '" "%~dp0' +
      $baseName +
      '.tmp" && del "%~dp0' +
      $baseName +
      '.tmp"' +
      "`r`n" +

      "@echo Push any key to close...`r`n" +
      "@pause > nul"
    )
}


# ============================================================
# Checksum
# ============================================================

if (-not $noSum) {

  [string] $checksum =
    $path + '.checksum'

  # Original file SHA-1
  Out-File `
    -FilePath $checksum `
    -Encoding Default `
    -InputObject (
      (CertUtil -hashfile $path SHA1 |
        findstr -v ':').Replace(' ', '') +
      ' ' +
      (Split-Path $path -Leaf)
    )

  # Split file SHA-1
  foreach ($destPath in $destList) {

    Out-File `
      -Append `
      -FilePath $checksum `
      -Encoding Default `
      -InputObject (
        (CertUtil -hashfile $destPath SHA1 |
          findstr -v ':').Replace(' ', '') +
        ' ' +
        (Split-Path $destPath -Leaf)
      )
  }
}


# ============================================================
# Hash test
#
# This calculates the SHA-1 of:
#
#   .001 + .002 + .003 + ...
#
# without creating a joined temporary file.
# ============================================================

if (-not $noTest) {

  [string] $hashTestPs1 =
    $path + '.hash.test.ps1'

  [string] $hashTestBat =
    $path + '.hash.test.bat'


  # ----------------------------------------------------------
  # PowerShell hash test script
  # ----------------------------------------------------------

  $hashTestScript = @"
`$ErrorActionPreference = 'Stop'

# Files belonging to this split set
`$baseName = '$baseName'
`$directory = Split-Path -Parent `$MyInvocation.MyCommand.Path

# Checksum file
`$checksumFile = Join-Path `$directory ('$baseName.checksum')

if (-not (Test-Path `$checksumFile)) {
    Write-Host
    Write-Host 'ERROR: Checksum file not found:'
    Write-Host `$checksumFile
    Write-Host
    Write-Host 'Press any key to close...'
    `$Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown') | Out-Null
    exit 1
}

# ----------------------------------------------------------
# Read expected original SHA-1
# ----------------------------------------------------------

`$checksumLines = Get-Content -LiteralPath `$checksumFile

`$originalLine = `$checksumLines |
    Where-Object {
        `$_.TrimEnd().EndsWith(' ' + `$baseName)
    } |
    Select-Object -First 1

if (-not `$originalLine) {
    Write-Host
    Write-Host 'ERROR: Original file checksum not found.'
    Write-Host
    Write-Host 'Press any key to close...'
    `$Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown') | Out-Null
    exit 1
}

`$expectedHash =
    (`$originalLine -split '\s+')[0].ToLower()

Write-Host
Write-Host 'Expected SHA-1:'
Write-Host `$expectedHash
Write-Host

# ----------------------------------------------------------
# Find ONLY this file's split parts
# ----------------------------------------------------------

`$parts = Get-ChildItem -LiteralPath `$directory -File |
    Where-Object {
        `$_.Name -match ('^' + [regex]::Escape(`$baseName) + '\.\d{3}$')
    } |
    Sort-Object {
        [int](`$_.Name -replace '^.*\.(\d{3})$', '`$1')
    }

if (`$parts.Count -eq 0) {
    Write-Host
    Write-Host 'ERROR: No split files found.'
    Write-Host
    Write-Host 'Press any key to close...'
    `$Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown') | Out-Null
    exit 1
}

Write-Host 'Split files:'

foreach (`$part in `$parts) {
    Write-Host ('  ' + `$part.Name)
}

Write-Host
Write-Host 'Calculating SHA-1...'
Write-Host

# ----------------------------------------------------------
# Calculate SHA-1 as if all split files were one file
# ----------------------------------------------------------

`$sha = [System.Security.Cryptography.SHA1]::Create()

[byte[]] `$buffer =
    New-Object byte[] (4MB)

foreach (`$part in `$parts) {

    Write-Host ('Hashing: ' + `$part.Name)

    `$stream =
        [System.IO.File]::OpenRead(`$part.FullName)

    try {

        while (
            (`$read = `$stream.Read(
                `$buffer,
                0,
                `$buffer.Length
            )) -gt 0
        ) {

            `$sha.TransformBlock(
                `$buffer,
                0,
                `$read,
                `$buffer,
                0
            ) | Out-Null
        }

    }
    finally {
        `$stream.Close()
    }
}

`$sha.TransformFinalBlock(
    `$buffer,
    0,
    0
) | Out-Null

`$actualHash =
    [BitConverter]::ToString(
        `$sha.Hash
    ).Replace('-', '').ToLower()

Write-Host
Write-Host 'Calculated SHA-1:'
Write-Host `$actualHash
Write-Host

# ----------------------------------------------------------
# Compare
# ----------------------------------------------------------

if (`$actualHash -eq `$expectedHash) {

    Write-Host '========================================'
    Write-Host 'HASH TEST: OK'
    Write-Host 'The split files match the original file.'
    Write-Host '========================================'

    `$exitCode = 0

}
else {

    Write-Host '========================================'
    Write-Host 'HASH TEST: FAILED'
    Write-Host 'The split files do NOT match the original file.'
    Write-Host '========================================'

    `$exitCode = 1
}

Write-Host
Write-Host 'Press any key to close...'
`$Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown') | Out-Null

exit `$exitCode
"@


  Out-File `
    -FilePath $hashTestPs1 `
    -Encoding UTF8 `
    -InputObject $hashTestScript


  # ----------------------------------------------------------
  # BAT launcher
  # ----------------------------------------------------------

  Out-File `
    -FilePath $hashTestBat `
    -Encoding Default `
    -InputObject (
      "@echo off`r`n" +
      'powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0' +
      (Split-Path $hashTestPs1 -Leaf) +
      '"'
    )
}


'OK'