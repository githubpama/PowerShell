﻿##
## Tests for PowerShell system lock down and constrained language mode restrictions
## These are Windows platform only tests
##

##
## ----------
## Test Note:
## ----------
## Since these tests change session and system state (constrained language and system lockdown)
## they will all use try/finally blocks instead of Pester AfterEach/AfterAll to ensure session 
## and system state is restored.
## Pester AfterEach, AfterAll is not reliable when the session is constrained language or locked down.
##

if ($IsWindows)
{
    $code = @'

    #region Using directives

    using System;
    using System.Globalization;
    using System.Reflection;
    using System.Collections;
    using System.Collections.Generic;
    using System.IO;
    using System.Security;
    using System.Runtime.InteropServices;
    using System.Threading;
    using System.Management.Automation;

    #endregion

    /// <summary>Adds a new type to the Application Domain</summary>
    [Cmdlet("Invoke", "LanguageModeTestingSupportCmdlet")]
    public sealed class InvokeLanguageModeTestingSupportCmdlet : PSCmdlet
    {
        [Parameter()]
        public SwitchParameter EnableFullLanguageMode
        {
            get { return enableFullLanguageMode; }
            set { enableFullLanguageMode = value; }
        }
        private SwitchParameter enableFullLanguageMode;

        [Parameter()]
        public SwitchParameter EnableConstrainedLanguageMode
        {
            get { return enableConstrainedLanguageMode; }
            set { enableConstrainedLanguageMode = value; }
        }
        private SwitchParameter enableConstrainedLanguageMode;

        [Parameter()]
        public SwitchParameter SetLockdownMode
        {
            get { return setLockdownMode; }
            set { setLockdownMode = value; }
        }
        private SwitchParameter setLockdownMode;

        [Parameter()]
        public SwitchParameter RevertLockdownMode
        {
            get { return revertLockdownMode; }
            set { revertLockdownMode = value; }
        }
        private SwitchParameter revertLockdownMode;
        
        protected override void BeginProcessing()
        {
            if (enableFullLanguageMode)
            {
                SessionState.LanguageMode = PSLanguageMode.FullLanguage;
            }

            if (enableConstrainedLanguageMode)
            {
                SessionState.LanguageMode = PSLanguageMode.ConstrainedLanguage;
            }

            if (setLockdownMode)
            {
                Environment.SetEnvironmentVariable("__PSLockdownPolicy", "0x80000007", EnvironmentVariableTarget.Machine);
            }

            if (revertLockdownMode)
            {
                Environment.SetEnvironmentVariable("__PSLockdownPolicy", null, EnvironmentVariableTarget.Machine);
            }            
        }
    }
'@

    if (-not (Get-Command Invoke-LanguageModeTestingSupportCmdlet -ea Ignore))
    {
        $moduleName = Get-RandomFileName
        $moduleDirectory = join-path $TestDrive\Modules $moduleName
        if (-not (Test-Path $moduleDirectory))
        {
            $null = New-Item -ItemType Directory $moduleDirectory -Force
        }

        try 
        { 
            Add-Type -TypeDefinition $code -OutputAssembly $moduleDirectory\TestCmdletForConstrainedLanguage.dll -ErrorAction Ignore 
        } catch {}

        Import-Module -Name $moduleDirectory\TestCmdletForConstrainedLanguage.dll
    }
} # end if ($IsWindows)

try
{
    $defaultParamValues = $PSDefaultParameterValues.Clone()
    $PSDefaultParameterValues["it:Skip"] = !$IsWindows

    Describe "Built-ins work within constrained language" -Tags 'Feature','RequireAdminOnWindows' {

        BeforeAll {
            $TestCasesBuiltIn = @(
                @{testName = "Verify built-in function"; scriptblock = { Get-Verb } }
                @{testName = "Verify built-in error variable"; scriptblock = { Write-Error SomeError -ErrorVariable ErrorOutput -ErrorAction SilentlyContinue; $ErrorOutput} }
            )
        }

        It "<testName>" -TestCases $TestCasesBuiltIn {

            param ($scriptblock)

            try
            {
                Invoke-LanguageModeTestingSupportCmdlet -EnableConstrainedLanguageMode

                $result = (& $scriptblock)
            }
            finally
            {
                Invoke-LanguageModeTestingSupportCmdlet -EnableFullLanguageMode
            }

            $result.Count | Should BeGreaterThan 0
        }
    }

    Describe "Background jobs" -Tags 'Feature','RequireAdminOnWindows' {

        Context "Background jobs in system lock down mode" {

            # TODO
            # Test is pending because PowerShell Core currently stubs out Windows system lockdown APIs
            It "Verifies that background jobs in system lockdown mode run in constrained language" -Pending {

                try
                {
                    Invoke-LanguageModeTestingSupportCmdlet -SetLockdownMode

                    $job = Start-Job -ScriptBlock { [object]::Equals("A", "B") } | Wait-Job
                    $expectedError = $job.ChildJobs[0].Error
                    $job | Remove-Job
                }
                finally
                {
                    Invoke-LanguageModeTestingSupportCmdlet -RevertLockdownMode
                }

                $expectedError.FullyQualifiedErrorId | Should Match "MethodInvocationNotSupportedInConstrainedLanguage"
            }
        }

        Context "Background jobs within inconsistent mode" {

            It "Verifies that background job is denied when mode is inconsistent" {

                try
                {
                    Invoke-LanguageModeTestingSupportCmdlet -EnableConstrainedLanguageMode

                    Start-Job { [object]::Equals("A", "B") }
                    throw "No Exception!"
                }
                catch 
                {
                    $exception = $_
                }
                finally
                {
                    Invoke-LanguageModeTestingSupportCmdlet -EnableFullLanguageMode
                }

                $exception.FullyQualifiedErrorId | Should Match "CannotStartJobInconsistentLanguageMode"
            }
        }
    }

    Describe "Add-Type in constrained language" -Tags 'Feature','RequireAdminOnWindows' {

        It "Verifies Add-Type fails in constrained language mode" {

            try
            {
                Invoke-LanguageModeTestingSupportCmdlet -EnableConstrainedLanguageMode

                Add-Type -TypeDefinition 'public class ConstrainedLanguageTest { public static string Hello = "HelloConstrained"; }'
                throw "No Exception!"
            }
            catch
            {
                $exception = $_
            }
            finally
            {
                Invoke-LanguageModeTestingSupportCmdlet -EnableFullLanguageMode
            }

            $exception.FullyQualifiedErrorId | Should Match "CannotDefineNewType"
        }

        It "Verifies Add-Type works back in full language mode again" {
            Add-Type -TypeDefinition 'public class AfterFullLanguageTest { public static string Hello = "HelloAfter"; }'
            [AfterFullLanguageTest]::Hello | Should Be "HelloAfter"
        }
    }

    Describe "New-Object in constrained language" -Tags 'Feature','RequireAdminOnWindows' {

        Context "New-Object with dotNet types" {

            It "Verifies New-Object works in constrained language of allowed string type" {

                try
                {
                    Invoke-LanguageModeTestingSupportCmdlet -EnableConstrainedLanguageMode

                    $resultString = New-Object System.String "Hello"
                }
                finally
                {
                    Invoke-LanguageModeTestingSupportCmdlet -EnableFullLanguageMode
                }

                $resultString | Should Be "Hello"
            }

            It "Verifies New-Object throws error in constrained language for disallowed IntPtr type" {

                try
                {
                    Invoke-LanguageModeTestingSupportCmdlet -EnableConstrainedLanguageMode

                    New-Object System.IntPtr 1234
                    throw "No Exception!"
                }
                catch
                {
                    $exception = $_
                }
                finally
                {
                    Invoke-LanguageModeTestingSupportCmdlet -EnableFullLanguageMode
                }

                $exception.FullyQualifiedErrorId | Should Match "CannotCreateTypeConstrainedLanguage"
            }

            It "Verifies New-Object works for IntPtr type back in full language mode again" {

                New-Object System.IntPtr 1234 | Should Be 1234
            }
        }

        Context "New-Object with COM types" {

            # TODO
            # Test is pending because PowerShell Core currently stubs out Windows system lockdown APIs
            It "Verifies New-Object with COM types is disallowed in system lock down" -Pending {

                try
                {
                    Invoke-LanguageModeTestingSupportCmdlet -SetLockdownMode -EnableConstrainedLanguageMode

                    New-Object -Com ADODB.Parameter
                    throw "No Exception!"
                }
                catch
                {
                    $exception = $_
                }
                finally
                {
                    Invoke-LanguageModeTestingSupportCmdlet -RevertLockdownMode -EnableFullLanguageMode
                }

                $exception.FullyQualifiedErrorId | Should Match "CannotCreateComTypeConstrainedLanguage"
            }

            It "Verifies New-Object with COM types works back in full language mode again" {

                $result = New-Object -ComObject ADODB.Parameter
                $result.Direction | Should Be 1
            }
        }
    }

    Describe "New-Item command on function drive in constrained language" -Tags 'Feature','RequireAdminOnWindows' {

        It "Verifies New-Item directory on function drive is not allowed in constrained language mode" {

            try
            {
                Invoke-LanguageModeTestingSupportCmdlet -EnableConstrainedLanguageMode

                $null = New-Item -Path function:\SomeEvilFunction -ItemType Directory -Value SomeBadScriptBlock -ErrorAction Stop
                throw "No Exception!"
            }
            catch
            {
                $exception = $_
            }
            finally
            {
                Invoke-LanguageModeTestingSupportCmdlet -EnableFullLanguageMode
            }

            $exception.FullyQualifiedErrorId | Should Match "NotSupported"
        }
    }

    Describe "Script debugging in constrained language" -Tags 'Feature','RequireAdminOnWindows' {

        It "Verifies that a debugging breakpoint cannot be set in constrained language and no system lockdown" {

            try
            {
                Invoke-LanguageModeTestingSupportCmdlet -EnableConstrainedLanguageMode

                function MyDebuggerFunction {}
                Set-PSBreakpoint -Command MyDebuggerFunction
                throw "No Exception!"
            }
            catch
            {
                $exception = $_
            }
            finally
            {
                Invoke-LanguageModeTestingSupportCmdlet -EnableFullLanguageMode
            }

            $exception.FullyQualifiedErrorId | Should Match "CannotSetBreakpointInconsistentLanguageMode"
        }
        
        # TODO
        # Test is pending because PowerShell Core currently stubs out Windows system lockdown APIs
        It "Verifies that a debugging breakpoint can be set in constrained language with system lockdown" -Pending {

            try
            {
                Invoke-LanguageModeTestingSupportCmdlet -SetLockdownMode -EnableConstrainedLanguageMode

                function MyDebuggerFunction2 {}
                $Global:DebuggingOk = $null
                $null = Set-PSBreakpoint -Command MyDebuggerFunction2 -Action { $Global:DebuggingOk = "DebuggingOk" }
                MyDebuggerFunction2
            }
            finally
            {
                Invoke-LanguageModeTestingSupportCmdlet -RevertLockdownMode -EnableFullLanguageMode
            }

            $Global:DebuggingOk | Should Be "DebuggingOk"
        }

        # TODO
        # Test is pending because PowerShell Core currently stubs out Windows system lockdown APIs
        It "Verifies that debugger commands do not run in full language mode when system is locked down" -Pending {

            try
            {
                Invoke-LanguageModeTestingSupportCmdlet -SetLockdownMode -EnableConstrainedLanguageMode

                function MyDebuggerFunction3 {}
                $null = Set-PSBreakpoint -Command MyDebuggerFunction3 -Action { $Global:dbgResult = [object]::Equals("A", "B") }

                $restoreEAPreference = $ErrorActionPreference
                $ErrorActionPreference = "Stop"
                MyDebuggerFunction3
                throw "No Exception!"
            }
            catch
            {
                $exception = $_
            }
            finally
            {
                if ($restoreEAPreference -ne $null) { $ErrorActionPreference = $restoreEAPreference }
                Invoke-LanguageModeTestingSupportCmdlet -RevertLockdownMode -EnableFullLanguageMode
            }

            $exception.FullyQualifiedErrorId | Should Match "MethodInvocationNotSupportedInConstrainedLanguage"
        }

        # TODO
        # Test is pending because PowerShell Core currently stubs out Windows system lockdown APIs
        It "Verifies that debugger command injection is blocked in system lock down" -Pending {

            $trustedScriptContent = @'
            function Trusted
            {
                param ($UserInput)

                Add-Type -TypeDefinition $UserInput
                try { $null = New-Object safe_738057 -ErrorAction Ignore } catch {}
                try { $null = New-Object pwnd_738057 -ErrorAction Ignore } catch {}
            }

            Trusted -UserInput 'public class safe_738057 { public safe_738057() { System.Environment.SetEnvironmentVariable("pwnd_738057", "False"); } }'

            "Hello World"
'@
            $trustedFile = Join-Path $TestDrive CommandInjectionDebuggingBlocked_System32.ps1

            try
            {
                Invoke-LanguageModeTestingSupportCmdlet -SetLockdownMode -EnableConstrainedLanguageMode

                Set-Content $trustedScriptContent -Path $trustedFile
                $env:pwnd_738057 = "False"
                Set-PSBreakpoint -Script $trustedFile -Line 12 -Action { Trusted -UserInput 'public class pwnd_738057 { public pwnd_738057() { System.Environment.SetEnvironmentVariable("pwnd_738057", "Pwnd"); } }' }
                & trustedFile
            }
            finally
            {
                Invoke-LanguageModeTestingSupportCmdlet -RevertLockdownMode -EnableFullLanguageMode
            }

            $env:pwnd_738057 | Should Not Be "Pwnd"
        }
    }
    
    Describe "Engine events in constrained language mode" -Tags 'Feature','RequireAdminOnWindows' {

        It "Verifies engine event in constrained language mode, its action runs as constrained" {

            try
            {
                Invoke-LanguageModeTestingSupportCmdlet -EnableConstrainedLanguageMode

                $job = Register-EngineEvent LockdownEvent -Action { [object]::Equals("A", "B") }
                $null = New-Event LockdownEvent
                Wait-Job $job
                Unregister-Event LockdownEvent
            }
            finally
            {
                Invoke-LanguageModeTestingSupportCmdlet -EnableFullLanguageMode
            }

            $job.Error.FullyQualifiedErrorId | Should Match "MethodInvocationNotSupportedInConstrainedLanguage"
        }
    }

    Describe "Module scope scripts in constrained language mode" -Tags 'Feature','RequireAdminOnWindows' {

        It "Verifies that while in constrained language mode script run in a module scope also runs constrained" {
            Import-Module PSDiagnostics
            $module = Get-Module PSDiagnostics

            try
            {
                Invoke-LanguageModeTestingSupportCmdlet -EnableConstrainedLanguageMode

                & $module { [object]::Equals("A", "B") }
                throw "No Exception!"
            }
            catch
            {
                $exception = $_
            }
            finally
            {
                Invoke-LanguageModeTestingSupportCmdlet -EnableFullLanguageMode
            }

            $exception.FullyQualifiedErrorId | Should Match "MethodInvocationNotSupportedInConstrainedLanguage"
        }
    }

    Describe "Switch -file in constrained language mode" -Tags 'Feature','RequireAdminOnWindows' {

        It "Verifies that switch -file will not work in constrained language without provider" {

            [initialsessionstate] $iss = [initialsessionstate]::Create()
            $iss.LanguageMode = "ConstrainedLanguage"
            [runspace] $rs = [runspacefactory]::CreateRunspace($iss)
            $rs.Open()
            $pl = $rs.CreatePipeline("switch -file $testDrive/foo.txt { 'A' { 'B' } }")

            try
            {
                $pl.Invoke()
                throw "No Exception!"
            }
            catch
            {
                $exception = $_
            }
            finally
            {
                $rs.Dispose()
            }

            $exception.FullyQualifiedErrorId | Should Match "DriveNotFoundException"
        }
    }

    Describe "Get content syntax in constrained language mode" -Tags 'Feature','RequireAdminOnWindows' {

        It "Verifies that the get content syntax returns null value in constrained language without provider" {

            $iss = [initialsessionstate]::Create()
            $iss.LanguageMode = "ConstrainedLanguage"
            $rs = [runspacefactory]::CreateRunspace($iss)
            $rs.Open()
            $pl = $rs.CreatePipeline('${' + "$testDrive/foo.txt}")

            $result = $pl.Invoke()
            $rs.Dispose()

            $result[0] | Should BeNullOrEmpty
        }
    }

    Describe "Stream redirection in constrained language mode" -Tags 'Feature','RequireAdminOnWindows' {

        It "Verifies that stream redirection doesn't work in constrained language mode without provider" {

            $iss = [initialsessionstate]::CreateDefault2()
            $iss.Providers.Clear()
            $iss.LanguageMode = "ConstrainedLanguage"
            $rs = [runspacefactory]::CreateRunspace($iss)
            $rs.Open()
            $pl = $rs.CreatePipeline('"Hello" > c:\temp\foo.txt')

            try
            {
                $pl.Invoke()
                throw "No Exception!"
            }
            catch
            {
                $exception = $_
            }
            finally
            {
                $rs.Dispose()
            }

            $exception.FullyQualifiedErrorId | Should Match "CmdletInvocationException"
        }
    }

    Describe "Invoke-Expression in constrained language mode" -Tags 'Feature','RequireAdminOnWindows' {

        BeforeAll {

            function VulnerableFunctionFromFullLanguage { Invoke-Expression $Args[0] }

            $TestCasesIEX = @(
                @{testName = "Verifies direct Invoke-Expression does not bypass constrained language mode"; 
                  scriptblock = { Invoke-Expression '[object]::Equals("A", "B")' } }
                @{testName = "Verifies indirect Invoke-Expression does not bypass constrained language mode"; 
                  scriptblock = { VulnerableFunctionFromFullLanguage '[object]::Equals("A", "B")' } }
            )
        }

        It "<testName>" -TestCases $TestCasesIEX {

            param ($scriptblock)

            try
            {
                Invoke-LanguageModeTestingSupportCmdlet -EnableConstrainedLanguageMode

                & $scriptblock
                throw 'No Exception!'
            }
            catch
            {
                $exception = $_
            }
            finally
            {
                Invoke-LanguageModeTestingSupportCmdlet -EnableFullLanguageMode
            }

            $exception.FullyQualifiedErrorId | Should Match "MethodInvocationNotSupportedInConstrainedLanguage"
        }
    }

    Describe "Dynamic method invocation in constrained language mode" -Tags 'Feature','RequireAdminOnWindows' {

        It "Verifies dynamic method invocation does not bypass constrained language mode" {

            try
            {
                Invoke-LanguageModeTestingSupportCmdlet -EnableConstrainedLanguageMode

                $type = [IO.Path]
                $method = "GetRandomFileName"
                $type::$method()
                throw 'No Exception!'
            }
            catch
            {
                $exception = $_
            }
            finally
            {
                Invoke-LanguageModeTestingSupportCmdlet -EnableFullLanguageMode
            }

            $exception.FullyQualifiedErrorId | Should Match "MethodInvocationNotSupportedInConstrainedLanguage"
        }

        It "Verifies dynamic methods invocation does not bypass constrained language mode" {

            try
            {
                Invoke-LanguageModeTestingSupportCmdlet -EnableConstrainedLanguageMode

                $type = [IO.Path]
                $methods = "GetRandomFileName","GetTempPath"
                $type::($methods[0])()
                throw 'No Exception!'
            }
            catch
            {
                $exception = $_
            }
            finally
            {
                Invoke-LanguageModeTestingSupportCmdlet -EnableFullLanguageMode
            }

            $exception.FullyQualifiedErrorId | Should Match "MethodInvocationNotSupportedInConstrainedLanguage"
        }
    }

    Describe "Tab expansion in constrained language mode" -Tags 'Feature','RequireAdminOnWindows' {

        It "Verifies that tab expansion cannot convert disallowed IntPtr type" {

            try
            {
                Invoke-LanguageModeTestingSupportCmdlet -EnableConstrainedLanguageMode

                $result = @(TabExpansion2 '(1234 -as [IntPtr]).' 20 | % CompletionMatches | ? CompletionText -Match Pointer)
            }
            finally
            {
                Invoke-LanguageModeTestingSupportCmdlet -EnableFullLanguageMode
            }

            $result.Count | Should Be 0
        }
    }

    Describe "Variable AllScope in constrained language mode" -Tags 'Feature','RequireAdminOnWindows' {

        It "Verifies Set-Variable cannot create AllScope in constrained language" {
        
            try
            {
                Invoke-LanguageModeTestingSupportCmdlet -EnableConstrainedLanguageMode

                Set-Variable -Name SetVariableAllScopeNotSupported -Value bar -Option AllScope
                throw "No Exception!"
            }
            catch
            {
                $exception = $_
            }
            finally
            {
                Invoke-LanguageModeTestingSupportCmdlet -EnableFullLanguageMode
            }

            $exception.FullyQualifiedErrorId | Should Match "NotSupported"
        }

        It "Verifies New-Variable cannot create AllScope in constrained language" {
        
            try
            {
                Invoke-LanguageModeTestingSupportCmdlet -EnableConstrainedLanguageMode

                New-Variable -Name NewVarialbeAllScopeNotSupported -Value bar -Option AllScope
                throw "No Exception!"
            }
            catch
            {
                $exception = $_
            }
            finally
            {
                Invoke-LanguageModeTestingSupportCmdlet -EnableFullLanguageMode
            }

            $exception.FullyQualifiedErrorId | Should Match "NotSupported"
        }
    }

    Describe "Data section additional commands in constrained language" -Tags 'Feature','RequireAdminOnWindows' {

        function InvokeDataSectionConstrained
        {
            try
            {
                Invoke-Expression 'data foo -SupportedCommand Add-Type { Add-Type }'
                throw "No Exception!"
            }
            catch
            {
                $exception = $_
            }

            return $exception
        }

        It "Verifies data section Add-Type additional command is disallowed in constrained language" {

            try
            {
                Invoke-LanguageModeTestingSupportCmdlet -EnableConstrainedLanguageMode

                $exception1 = InvokeDataSectionConstrained
                # Repeat to make sure the first time properly restored the language mode to constrained.
                $exception2 = InvokeDataSectionConstrained
            }
            finally
            {
                Invoke-LanguageModeTestingSupportCmdlet -EnableFullLanguageMode
            }

            $exception1.FullyQualifiedErrorId | Should Match "DataSectionAllowedCommandDisallowed"
            $exception2.FullyQualifiedErrorId | Should Match "DataSectionAllowedCommandDisallowed"
        }

        It "Verifies data section with no-constant expression Add-Type additional command is disallowed in constrained language" {

            try
            {
                Invoke-LanguageModeTestingSupportCmdlet -EnableConstrainedLanguageMode

                $addedCommand = "Add-Type"
                Invoke-Expression 'data foo -SupportedCommand $addedCommand { Add-Type }'
                throw "No Exception!"
            }
            catch
            {
                $exception = $_
            }
            finally
            {
                Invoke-LanguageModeTestingSupportCmdlet -EnableFullLanguageMode
            }

            $exception.FullyQualifiedErrorId | Should Match "DataSectionAllowedCommandDisallowed"
        }
    }

    Describe "Import-LocalizedData additional commands in constrained language" -Tags 'Feature','RequireAdminOnWindows' {

        It "Verifies Import-LocalizedData disallows Add-Type in constrained language" {

            try
            {
                Invoke-LanguageModeTestingSupportCmdlet -EnableConstrainedLanguageMode

                $localizedDataFileName = Join-Path $TestDrive ImportLocalizedDataAdditionalCommandsNotSupported.psd1
                $null = New-Item -ItemType File -Path $localizedDataFileName -Force
                Import-LocalizedData -SupportedCommand Add-Type -BaseDirectory $TestDrive -FileName ImportLocalizedDataAdditionalCommandsNotSupported
                throw "No Exception!"
            }
            catch
            {
                $exception = $_
            }
            finally
            {
                Invoke-LanguageModeTestingSupportCmdlet -EnableFullLanguageMode
            }

            $exception.FullyQualifiedErrorId | Should Match "CannotDefineSupportedCommand"
        }
    }

    Describe "Where and Foreach operators should not allow unapproved types in constrained language" -Tags 'Feature','RequireAdminOnWindows' {

        BeforeAll {

            $script1 = @'
                $data = @(
                    @{
                        Node = "first"
                        Value1 = 1
                        Value2 = 2
                        first = $true
                    }
                    @{
                        Node = "second"
                        Value1 = 3
                        Value2 = 4
                        Second = $true
                    }
                    @{
                        Node = "third"
                        Value1 = 5
                        Value2 = 6
                        third = $true
                    }
                )

                $result = $data.where{$_.Node -eq "second"}
                Write-Output $result

                # Execute method in scriptblock of where operator, should throw in ConstrainedLanguage mode.
                $data.where{[system.io.path]::GetRandomFileName() -eq "Hello"}
'@

            $script2 = @'
                $data = @(
                    @{
                        Node = "first"
                        Value1 = 1
                        Value2 = 2
                        first = $true
                    }
                    @{
                        Node = "second"
                        Value1 = 3
                        Value2 = 4
                        Second = $true
                    }
                    @{
                        Node = "third"
                        Value1 = 5
                        Value2 = 6
                        third = $true
                    }
                )

                $result = $data.foreach('value1')
                Write-Output $result

                # Execute method in scriptblock of foreach operator, should throw in ConstrainedLanguage mode.
                $data.foreach{[system.io.path]::GetRandomFileName().Length}
'@

            $script3 = @'
            # Method call should throw error.
            (Get-Process powershell*).Foreach('GetHashCode')
'@

            $script4 = @'
            # Where method call should throw error.
            (get-process powershell).where{$_.GetType().FullName -match "process"}
'@

            $TestCasesForeach = @(
                @{testName = "Verify where statement with invalid method call in constrained language is disallowed"; script = $script1 }
                @{testName = "Verify foreach statement with invalid method call in constrained language is disallowed"; script = $script2 }
                @{testName = "Verify foreach statement with embedded method call in constrained language is disallowed"; script = $script3 }
                @{testName = "Verify where statement with embedded method call in constrained language is disallowed"; script = $script4 }
            )
        }        

        It "<testName>" -TestCases $TestCasesForeach {

            param (
                [string] $script
            )

            try
            {
                Invoke-LanguageModeTestingSupportCmdlet -EnableConstrainedLanguageMode

                # Scriptblock must be created inside constrained language.
                $sb = [scriptblock]::Create($script)
                & sb
                throw "No Exception!"
            }
            catch
            {
                $exception = $_
            }
            finally
            {
                Invoke-LanguageModeTestingSupportCmdlet -EnableFullLanguageMode
            }

            $exception.FullyQualifiedErrorId | Should Match "MethodInvocationNotSupportedInConstrainedLanguage"
        }
    }

    # End Describe blocks
}
finally
{
    if ($defaultParamValues -ne $null)
    {
        $Global:PSDefaultParameterValues = $defaultParamValues
    }
}
