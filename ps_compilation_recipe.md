You are an expert PowerShell and .NET developer. Your task is to refactor and optimize the embedded C# (.NET) compilation mechanism in the target PowerShell 5.1 script.

### Background & Objective
By default, naive invocations of `Add-Type -TypeDefinition $Source -Language CSharp` in Windows PowerShell 5.1 compile in Debug/unoptimized mode, leave temporary files on disk, and fail if the script is executed multiple times in the same session. Furthermore, using `Add-Type -CompilerParameters` in PowerShell 5.1 bypasses PowerShell's default assembly reference list, which can cause missing assembly errors for `System.dll`, `System.Core.dll`, etc.

You must upgrade the script's C# compilation block with the robust, high-performance PowerShell 5.1 compilation recipe detailed below.

### The Optimization Recipe Requirements:

1. **Type Redefinition Guard**:
   Check if the primary type already exists before compiling using `[System.Management.Automation.PSTypeName]`:
   ```powershell
   if (-not ([System.Management.Automation.PSTypeName]'<Namespace.TypeName>').Type) {
       # Compilation logic here
   } else {
       Write-Warning "Using existing C# definition. If you modified the C# code, please restart PowerShell."
   }
   ```

2. **Explicit CompilerParameters Configuration**:
   Create an instance of `System.CodeDom.Compiler.CompilerParameters`:
   - Set `$Params.CompilerOptions = "/optimize"` (or `"/optimize+"`) to enable IL optimization and JIT inlining.
   - Set `$Params.GenerateInMemory = $true` to prevent disk writes.
   - Set `$Params.IncludeDebugInformation = $false` for a clean release build.

3. **Dynamic Framework Assembly Resolution**:
   Explicitly resolve the .NET runtime directory and add necessary framework assemblies to `$Params.ReferencedAssemblies`:
   ```powershell
   $runtimeDir = [Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()
   $assembliesToLoad = @("System.dll", "System.Core.dll") # Add any additional assemblies required by the C# code
   foreach ($dll in $assembliesToLoad) {
       $dllPath = Join-Path $runtimeDir $dll
       if (Test-Path $dllPath) {
           [void]$Params.ReferencedAssemblies.Add($dllPath)
       }
   }
   ```

4. **Pass CompilerParameters to Add-Type**:
   Invoke `Add-Type` using the parameters object:
   ```powershell
   Add-Type -TypeDefinition $Source -CompilerParameters $Params
   ```

### Instructions for the Script Refactor:
1. Identify all embedded C# code definitions (`$Source` / `$Definition` / `$csharpCode` strings) and determine their primary namespace and class names.
2. Inspect the C# code for any framework dependencies (e.g. `System.Numerics.dll`, `System.Xml.dll`, `System.Speech.dll`, `System.Windows.Forms.dll`, etc.) and add them to `$assembliesToLoad` alongside `System.dll` and `System.Core.dll`.
3. Replace the existing `Add-Type` invocation with the guarded, optimized recipe.
4. Ensure no existing script logic, parameter handling, or C# code semantics are broken.
