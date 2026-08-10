$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$WindowsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$ReleaseRoot = Join-Path $WindowsRoot "release\win-x64"
$PracticeOutput = Join-Path $ReleaseRoot "错题刷题工具"
$CaptureOutput = Join-Path $ReleaseRoot "错题截图整理"

Push-Location $WindowsRoot
try {
    dotnet restore ".\MedicalQuestionSuite.Tests\MedicalQuestionSuite.Tests.csproj"
    dotnet restore ".\MedicalQuestionPractice.Windows\MedicalQuestionPractice.Windows.csproj"
    dotnet restore ".\WrongQuestionCapture.Windows\WrongQuestionCapture.Windows.csproj"

    dotnet test ".\MedicalQuestionSuite.Tests\MedicalQuestionSuite.Tests.csproj" -c Release --no-restore

    if (Test-Path $ReleaseRoot) {
        Remove-Item -LiteralPath $ReleaseRoot -Recurse -Force
    }
    New-Item -ItemType Directory -Path $PracticeOutput -Force | Out-Null
    New-Item -ItemType Directory -Path $CaptureOutput -Force | Out-Null

    dotnet publish ".\MedicalQuestionPractice.Windows\MedicalQuestionPractice.Windows.csproj" `
        -c Release -r win-x64 --self-contained true --no-restore `
        -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true `
        -o $PracticeOutput

    dotnet publish ".\WrongQuestionCapture.Windows\WrongQuestionCapture.Windows.csproj" `
        -c Release -r win-x64 --self-contained true --no-restore `
        -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true `
        -o $CaptureOutput

    $PracticeZip = Join-Path $ReleaseRoot "错题刷题工具-win-x64.zip"
    $CaptureZip = Join-Path $ReleaseRoot "错题截图整理-win-x64.zip"
    Compress-Archive -Path (Join-Path $PracticeOutput "*") -DestinationPath $PracticeZip -Force
    Compress-Archive -Path (Join-Path $CaptureOutput "*") -DestinationPath $CaptureZip -Force

    Get-FileHash -Algorithm SHA256 $PracticeZip, $CaptureZip |
        Format-Table -AutoSize Path, Hash
}
finally {
    Pop-Location
}
