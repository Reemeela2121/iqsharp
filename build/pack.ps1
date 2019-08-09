# Copyright (c) Microsoft Corporation. All rights reserved.
# Licensed under the MIT License.

$ErrorActionPreference = 'Stop'

& "$PSScriptRoot/set-env.ps1"
$all_ok = $True

function Pack-Nuget() {
    param(
        [string]$project
    );

    dotnet pack (Join-Path $PSScriptRoot $project) `
        --no-build `
        -c $Env:BUILD_CONFIGURATION `
        -v $Env:BUILD_VERBOSITY `
        -o $Env:NUGET_OUTDIR `
        /property:Version=$Env:ASSEMBLY_VERSION `
        /property:PackageVersion=$Env:NUGET_VERSION

    if  ($LastExitCode -ne 0) {
        Write-Host "##vso[task.logissue type=error;]Failed to build $project."
        $script:all_ok = $False
    }
}

function Pack-Wheel() {
    param(
        [string] $Path
    );

    $result = 0

    Push-Location (Join-Path $PSScriptRoot $Path)
        python setup.py bdist_wheel

        if  ($LastExitCode -ne 0) {
            Write-Host "##vso[task.logissue type=error;]Failed to build $Path."
            $script:all_ok = $False
        } else {
            Copy-Item "dist/*.whl" $Env:PYTHON_OUTDIR
        }
    Pop-Location

}

function Pack-Image() {
    param(
        [string] $RepoName,
        [string] $Dockerfile
    );

    if (($Env:AGENT_OS -ne $null) -and ($Env:AGENT_OS.StartsWith("Win"))) {
        Write-Host "##vso[task.logissue type=warning;]cannot create docker image on Windows."
        return
    }

    Try {
        docker version
    } Catch {
        Write-Host "##vso[task.logissue type=warning;]docker not installed. Will skip creation of image for $Dockerfile"
        return
    }

    docker build `
        <# We treat $DROP_DIR as the build context, as we will need to ADD
           nuget packages into the image. #> `
        $Env:DROPS_DIR `
        <# This means that the Dockerfile lives outside the build context. #> `
        -f (Join-Path $PSScriptRoot $Dockerfile) `
        <# Next, we tell Docker what version of IQ# to install. #> `
        --build-arg IQSHARP_VERSION=$Env:NUGET_VERSION `
        <# Finally, we tag the image with the current build number. #> `
        -t "${Env:DOCKER_PREFIX}${RepoName}:${Env:BUILD_BUILDNUMBER}"

    if  ($LastExitCode -ne 0) {
        Write-Host "##vso[task.logissue type=error;]Failed to create docker image for $Dockerfile."
        $script:all_ok = $False
    }
}

function Pack-CondaRecipe() {
    param(
        [string] $Path
    );

    if (-not (Get-Command conda-build -ErrorAction SilentlyContinue)) {
        Write-Host "##vso[task.logissue type=warning;] conda-build not installed. " + `
                   "Will skip creation of conda package for $Path.";
        return;
    }

    conda build (Resolve-Path $Path);

    if ($LastExitCode -ne 0) {
        Write-Host "##vso[task.logissue type=error;]Failed to create conda package for $Path."
        $script:all_ok = $False
    } else {
        Copy-Item (conda build (Resolve-Path $Path) --output) $Env:CONDA_OUTDIR;
    }
}

Write-Host "##[info]Packing IQ# library..."
Pack-Nuget '../src/Core/Core.csproj'

Write-Host "##[info]Packing IQ# tool..."
Pack-Nuget '../src/Tool/Tool.csproj'

Write-Host "##[info]Packing Python wheel..."
python --version
Pack-Wheel '../src/Python/'

Write-Host "##[info]Packing Docker image..."
Pack-Image -RepoName "iqsharp-base" -Dockerfile '../images/iqsharp-base/Dockerfile'

Write-Host "##[info]Packing conda recipe..."
Pack-CondaRecipe -Path "../conda-recipes/iqsharp"

if (-not $all_ok) {
    throw "At least one package failed to build. Check the logs."
}