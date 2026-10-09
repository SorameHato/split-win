# ============================================================
# split-win
# Modified version
#
# Features:
#   - Human-readable size arguments: 9gb, 1024mb, 1tb, etc.
#   - Portable .join.bat
#   - Portable .join.test.bat
#   - Additional .hash.test.bat
#   - Streaming SHA-1 verification without temporary joined file
# ============================================================


# ============================================================
# Parameters
# ============================================================

param (
  [Parameter(Position = 0, Mandatory = $true)]
  [string] $path,

  [string] $size = '256mb',

  [switch] $noJoin,

  [switch] $noTest,

  [switch] $noSum
)


# ============================================================
# Convert human-readable size to bytes
# ============================================================

if ($size -match '^(\d+(?:\.\d+)?)\s*(b|kb|mb|gb|tb)$') {

  $number = [double]$Matches[1]
  $unit = $Matches[2].ToLower()

  $multiplier = switch ($unit) {
    'b'  { 1 }
    'kb' { 1KB }
    'mb' { 1MB }
    'gb' { 1GB }
    'tb' { 1TB }
  }

  $sizeBytes = [Int64]($number * $multiplier)

}
else {

  # Also allow a plain integer byte count.
  if ($size -match '^\d+$') {
    $sizeBytes = [Int64]$size
  }
  else {
    throw "Invalid size format: $size"
  }
}


if ($sizeBytes -le 0) {
  throw "Size must be greater than zero."
}


# ============================================================
# Resolve input file
# ============================================================

$path = [System.IO.Path]::GetFullPath($path)

if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
  throw "File not found: $path"
}


# ============================================================
# File names
# ============================================================

[string] $baseName =
  Split-Path $path -Leaf

[string] $baseDir =
  Split-Path $path -Parent


# ============================================================
# Open source file
# ============================================================

$source = [System.IO.File]::Open(
  $path,
  [System.IO.FileMode]::Open,
  [System.IO.FileAccess]::Read,
  [System.IO.FileShare]::Read
)


# ============================================================
# Split
# ============================================================

[byte[]] $buffer = New-Object byte[] (4MB)

$fileNum = 1

try {

  while ($source.Position -lt $source.Length) {

    $destPath =
      $path + '.' + $fileNum.ToString('000')

    Write-Host (
      'Creating: ' + $destPath
    )

    $dest = [System.IO.File]::Open(
      $destPath,
      [System.IO.FileMode]::Create,
      [System.IO.FileAccess]::Write,
      [System.IO.FileShare]::None
    )

    try {

      $remaining = $sizeBytes

      while ($remaining -gt 0 -and $source.Position -lt $source.Length) {

        $readSize = [Math]::Min(
          $buffer.Length,
          $remaining
        )

        $read = $source.Read(
          $buffer,
          0,
          $readSize
        )

        if ($read -le 0) {
          break
        }

        $dest.Write(
          $buffer,
          0,
          $read
        )

        $remaining -= $read
      }

    }
    finally {

      $dest.Close()
      $dest.Dispose()

    }

    $fileNum++
  }

}
finally {

  $source.Close()
  $source.Dispose()

}


# ============================================================
# Destination list
# ============================================================

$destList = @()

for ($i = 1; $i -lt $fileNum; $i++) {

  $destList += (
    $path + '.' + $i.ToString('000')
  )

}


# ============================================================
# Join command
# ============================================================

if (-not $noJoin) {

  [string] $cmdJoin =
    'COPY /b ' +
    [string]::Join(
      '+',
      ($destList | ForEach-Object {
        '"%~dp0' + (Split-Path $_ -Leaf) + '"'
      })
    ) +
    ' "%~dp0' + $baseName + '"'


  [string] $joinBat =
    $path + '.join.bat'


  @(
    '@echo off'
    $cmdJoin
    '@echo.'
    '@echo Join completed.'
    '@pause'
  ) |
    Set-Content `
      -LiteralPath $joinBat `
      -Encoding Default

}


# ============================================================
# Join test
# ============================================================

if (-not $noTest) {

  [string] $cmdJoinTest =
    'COPY /b ' +
    [string]::Join(
      '+',
      ($destList | ForEach-Object {
        '"%~dp0' + (Split-Path $_ -Leaf) + '"'
      })
    ) +
    ' "%~dp0' + $baseName + '.tmp"'


  [string] $cmdFC =
    'fc /b ' +
    '"%~dp0' + $baseName + '" ' +
    '"%~dp0' + $baseName + '.tmp" ' +
    '&& del "%~dp0' + $baseName + '.tmp"'


  [string] $joinTestBat =
    $path + '.join.test.bat'


  @(
    '@echo off'
    $cmdJoinTest
    $cmdFC
    '@echo.'
    '@echo Push any key to close...'
    '@pause > nul'
  ) |
    Set-Content `
      -LiteralPath $joinTestBat `
      -Encoding Default

}


# ============================================================
# SHA-1 checksum
# ============================================================

if (-not $noSum) {

  [string] $checksumFile =
    $path + '.checksum'


  Write-Host 'Calculating SHA-1 checksum...'


  $sha1 = [System.Security.Cryptography.SHA1]::Create()

  try {

    $stream = [System.IO.File]::OpenRead($path)

    try {

      $hashBytes = $sha1.ComputeHash($stream)

    }
    finally {

      $stream.Close()
      $stream.Dispose()

    }

  }
  finally {

    $sha1.Dispose()

  }


  $hash =
    [BitConverter]::ToString($hashBytes).Replace('-', '').ToLower()


  # Keep the original split-win style:
  # SHA1 + two spaces + filename
  $checksumLine =
    $hash + '  ' + $baseName


  Set-Content `
    -LiteralPath $checksumFile `
    -Value $checksumLine `
    -Encoding Default


  # Also append SHA-1 for each split file
  foreach ($dest in $destList) {

    $sha1 = [System.Security.Cryptography.SHA1]::Create()

    try {

      $stream = [System.IO.File]::OpenRead($dest)

      try {

        $hashBytes =
          $sha1.ComputeHash($stream)

      }
      finally {

        $stream.Close()
        $stream.Dispose()

      }

    }
    finally {

      $sha1.Dispose()

    }


    $hash =
      [BitConverter]::ToString($hashBytes).Replace('-', '').ToLower()


    Add-Content `
      -LiteralPath $checksumFile `
      -Value ($hash + '  ' + (Split-Path $dest -Leaf)) `
      -Encoding Default
  }

}


# ============================================================
# Generate hash.test.ps1
# ============================================================

[string] $hashTestPs1 =
  $path + '.hash.test.ps1'


[string] $hashTestBat =
  $path + '.hash.test.bat'


[string] $hashTestScript = @'
$ErrorActionPreference = 'Stop'

$directory = Split-Path -Parent $MyInvocation.MyCommand.Path

$baseName = '__BASE_NAME__'

$originalFile = Join-Path $directory $baseName

$checksumFile =
  Join-Path $directory ($baseName + '.checksum')


Write-Host '========================================'
Write-Host 'HASH TEST'
Write-Host '========================================'
Write-Host ''

Write-Host ('Directory : ' + $directory)
Write-Host ('Original  : ' + $baseName)
Write-Host ''


# ------------------------------------------------------------
# Find split files
# ------------------------------------------------------------

$pattern =
  '^' + [regex]::Escape($baseName) + '\.(\d{3})$'


$parts = @()

Get-ChildItem -LiteralPath $directory -File |
  ForEach-Object {

    if ($_.Name -match $pattern) {

      $parts += [PSCustomObject]@{
        Number = [int]$Matches[1]
        Path   = $_.FullName
        Name   = $_.Name
      }

    }

  }


$parts =
  $parts | Sort-Object Number


if ($parts.Count -eq 0) {
  throw 'No split files found.'
}


# ------------------------------------------------------------
# Check numbering
# ------------------------------------------------------------

for ($i = 0; $i -lt $parts.Count; $i++) {

  $expected = $i + 1

  if ($parts[$i].Number -ne $expected) {

    throw (
      'Missing split file: ' +
      $expected.ToString('000')
    )

  }

}


Write-Host 'Split files:'

foreach ($part in $parts) {

  $length =
    (Get-Item -LiteralPath $part.Path).Length

  Write-Host (
    ('  {0:000}: {1} ({2:N0} bytes)' -f
      $part.Number,
      $part.Name,
      $length)
  )

}

Write-Host ''


# ------------------------------------------------------------
# SHA-1 helper
# ------------------------------------------------------------

function Get-Sha1 {

  param (
    [Parameter(Mandatory = $true)]
    [string] $FilePath
  )


  $sha1 =
    [System.Security.Cryptography.SHA1]::Create()


  try {

    $stream =
      [System.IO.File]::OpenRead($FilePath)

    try {

      $hashBytes =
        $sha1.ComputeHash($stream)

    }
    finally {

      $stream.Close()
      $stream.Dispose()

    }

  }
  finally {

    $sha1.Dispose()

  }


  return (
    [BitConverter]::ToString($hashBytes).
      Replace('-', '').
      ToUpper()
  )

}


# ------------------------------------------------------------
# Original SHA-1
# ------------------------------------------------------------

Write-Host '1. Calculating original ZIP SHA-1...'

$originalHash =
  Get-Sha1 $originalFile

Write-Host ('   ' + $originalHash)
Write-Host ''


# ------------------------------------------------------------
# Concatenated split SHA-1
# ------------------------------------------------------------

Write-Host '2. Calculating SHA-1 of split files...'

$sha1 =
  [System.Security.Cryptography.SHA1]::Create()

try {

  $buffer =
    New-Object byte[] (4MB)


  foreach ($part in $parts) {

    Write-Host (
      '   ' + $part.Name + ' ...'
    ) -NoNewline


    $stream =
      [System.IO.File]::OpenRead($part.Path)

    try {

      while ($true) {

        $read =
          $stream.Read(
            $buffer,
            0,
            $buffer.Length
          )

        if ($read -eq 0) {
          break
        }

        $sha1.TransformBlock(
          $buffer,
          0,
          $read,
          $buffer,
          0
        ) | Out-Null

      }

    }
    finally {

      $stream.Close()
      $stream.Dispose()

    }

    Write-Host ' done'

  }


  $sha1.TransformFinalBlock(
    [byte[]]::new(0),
    0,
    0
  ) | Out-Null


  $partsHash =
    [BitConverter]::ToString(
      $sha1.Hash
    ).Replace('-', '').ToUpper()

}
finally {

  $sha1.Dispose()

}


Write-Host ''
Write-Host ('   Split SHA-1: ' + $partsHash)
Write-Host ''


# ------------------------------------------------------------
# Compare
# ------------------------------------------------------------

Write-Host '========================================'
Write-Host 'RESULT'
Write-Host '========================================'

Write-Host ('Original : ' + $originalHash)
Write-Host ('Split    : ' + $partsHash)
Write-Host ''


if ($originalHash -eq $partsHash) {

  Write-Host 'HASH TEST: OK'
  Write-Host ''
  Write-Host (
    'The original file and the concatenated split data '
    + 'are identical.'
  )

}
else {

  Write-Host 'HASH TEST: FAILED'
  Write-Host ''
  Write-Host (
    'The original file and the split data are different.'
  )

  exit 1

}


# ------------------------------------------------------------
# Optional .checksum comparison
# ------------------------------------------------------------

if (Test-Path -LiteralPath $checksumFile) {

  Write-Host ''
  Write-Host 'Checking .checksum...'


  $checksumHash = $null


  Get-Content `
    -LiteralPath $checksumFile `
    -Encoding Default |
    ForEach-Object {

      if (
        $_ -match
        '^\s*([0-9A-Fa-f]{40})\s{1,}(.+)$'
      ) {

        $hash = $Matches[1].ToUpper()
        $name = $Matches[2].Trim()

        # The filename may be garbled because of encoding.
        # Therefore compare the checksum against the
        # original SHA-1 as an additional verification.

        if (-not $checksumHash) {
          $checksumHash = $hash
        }

      }

    }


  if ($checksumHash) {

    Write-Host (
      'Checksum SHA-1: ' + $checksumHash
    )


    if ($checksumHash -eq $originalHash) {

      Write-Host (
        'CHECKSUM TEST: OK'
      )

    }
    else {

      Write-Host (
        'CHECKSUM TEST: FAILED'
      )

    }

  }
  else {

    Write-Host (
      'Could not read SHA-1 from .checksum.'
    )

  }

}


Write-Host ''
Write-Host '========================================'
Write-Host 'All tests completed.'
Write-Host '========================================'

'@


$hashTestScript =
  $hashTestScript.Replace(
    '__BASE_NAME__',
    $baseName
  )


Set-Content `
  -LiteralPath $hashTestPs1 `
  -Value $hashTestScript `
  -Encoding UTF8


# ============================================================
# Generate hash.test.bat
# ============================================================

@(
  '@echo off'
  'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0' +
    (Split-Path $hashTestPs1 -Leaf) +
    '"'
  '@echo.'
  '@echo Push any key to close...'
  '@pause > nul'
) |
  Set-Content `
    -LiteralPath $hashTestBat `
    -Encoding Default


# ============================================================
# Done
# ============================================================

Write-Host ''
Write-Host '========================================'
Write-Host 'Split completed.'
Write-Host '========================================'
Write-Host ''

Write-Host ('Original : ' + $path)
Write-Host ('Size     : ' + $sizeBytes.ToString('N0') + ' bytes')
Write-Host ('Parts    : ' + ($destList.Count))
Write-Host ''

Write-Host 'Generated files:'

if (-not $noJoin) {
  Write-Host ('  ' + (Split-Path $path -Leaf) + '.join.bat')
}

if (-not $noTest) {
  Write-Host ('  ' + (Split-Path $path -Leaf) + '.join.test.bat')
}

if (-not $noSum) {
  Write-Host ('  ' + (Split-Path $path -Leaf) + '.checksum')
}

Write-Host (
  '  ' + (Split-Path $hashTestBat -Leaf)
)

Write-Host ''