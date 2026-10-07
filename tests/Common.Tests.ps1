# Module-wide quality gates shared by every repository: manifest, help, and analyzer.
BeforeDiscovery {
    $script:ModuleDir = Get-ChildItem -Path ([System.IO.Path]::Combine($PSScriptRoot, '..', 'src')) -Directory | Select-Object -First 1
    $script:ModuleName = $script:ModuleDir.Name
    Import-Module -Name ([System.IO.Path]::Combine($script:ModuleDir.FullName, "$($script:ModuleName).psd1")) -Force
    $script:Commands = @(Get-Command -Module $script:ModuleName -CommandType Function | ForEach-Object { @{ Name = $_.Name } })
}

BeforeAll {
    $script:ModuleDir = Get-ChildItem -Path ([System.IO.Path]::Combine($PSScriptRoot, '..', 'src')) -Directory | Select-Object -First 1
    $script:ModuleName = $script:ModuleDir.Name
    $script:Manifest = [System.IO.Path]::Combine($script:ModuleDir.FullName, "$($script:ModuleName).psd1")
    Import-Module -Name $script:Manifest -Force
}

Describe 'Module quality gates' {
    It 'has a valid manifest' {
        { Test-ModuleManifest -Path $script:Manifest -ErrorAction Stop } | Should -Not -Throw
    }

    It 'exports exactly the functions listed in the manifest' {
        $manifestData = Import-PowerShellDataFile -Path $script:Manifest
        $exported = (Get-Command -Module $script:ModuleName -CommandType Function).Name | Sort-Object
        $exported | Should -Be ($manifestData.FunctionsToExport | Sort-Object)
    }

    It 'passes PSScriptAnalyzer with zero findings' {
        $settings = [System.IO.Path]::Combine($PSScriptRoot, '..', 'PSScriptAnalyzerSettings.psd1')
        $findings = @(Invoke-ScriptAnalyzer -Path $script:ModuleDir.FullName -Recurse -Settings $settings)
        ($findings | ForEach-Object { '{0}:{1} {2}' -f $_.ScriptName, $_.Line, $_.RuleName }) | Should -BeNullOrEmpty
    }
}

Describe 'Comment-based help for <Name>' -ForEach $script:Commands {
    BeforeAll {
        $script:Help = Get-Help -Name $Name -Full
        $script:Cmd = Get-Command -Name $Name
    }

    It 'has a synopsis' {
        $script:Help.Synopsis | Should -Not -BeNullOrEmpty
        $script:Help.Synopsis | Should -Not -Match ([regex]::Escape($Name))
    }

    It 'has a description' {
        ($script:Help.Description | Out-String).Trim() | Should -Not -BeNullOrEmpty
    }

    It 'has at least one example' {
        @($script:Help.Examples.Example).Count | Should -BeGreaterThan 0
    }

    It 'documents every parameter' {
        $common = [System.Management.Automation.PSCmdlet]::CommonParameters + [System.Management.Automation.PSCmdlet]::OptionalCommonParameters
        $params = $script:Cmd.Parameters.Keys | Where-Object { $_ -notin $common }
        foreach ($p in $params) {
            $doc = $script:Help.Parameters.Parameter | Where-Object Name -EQ $p
            ($doc.Description | Out-String).Trim() | Should -Not -BeNullOrEmpty -Because "parameter -$p should be documented"
        }
    }
}
