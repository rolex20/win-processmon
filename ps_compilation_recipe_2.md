# AI Prompt & Compilation/Optimization Recipe (Disk Cached)

# Role & Task
You are an expert Windows PowerShell 5.1 and .NET performance engineer.
Your task is to refactor the provided PowerShell 5.1 script to replace all standard `Add-Type -TypeDefinition` calls with the high-performance, disk-cached, optimized compilation recipe provided by `Import-OptimizedCSharp.ps1`.

---

## The Problem with `Add-Type -TypeDefinition` in PowerShell 5.1
1. **Slow Startup / JIT Cost**: Compiles on every script run, adding 1–3s latency.
2. **AppDomain Immutability**: Once a type/assembly is loaded into PowerShell's AppDomain, it cannot be unloaded or recompiled in that session.
3. **DLL File Locking**: `Add-Type` locks disk binaries, making iterative development and in-place cache replacement fail with file access errors.
4. **Unoptimized by Default**: Does not pass `/optimize+`, `/debug-`, or platform targets.

---

## The `Import-OptimizedCSharp.ps1` Recipe
The script `Import-OptimizedCSharp.ps1` provides a drop-in loader function:
`Import-OptimizedCSharp -Source <string> -ExpectedTypeName <string> -CallerScriptPath <string> [-Platform AnyCPU|x64] [-ReferencedAssemblies <string[]>] [-CacheRoot <string>] [-Force]`

### How the Recipe Works under the hood:
1. **AppDomain Short-Circuit**: Checks if `ExpectedTypeName` is already present in `[AppDomain]::CurrentDomain.GetAssemblies()` before doing any disk I/O or compilation.
2. **Deterministic SHA-256 Cache Key**: Hashes the calling script path, caller `LastWriteTimeUtc`, compilation platform (`AnyCPU` vs `x64`), referenced assemblies, and source code text.
3. **Disk Cache (`.cache/<ScriptName>.<platform>.<hash16>.dll`)**:
   - Recompiles only when `-Force` is passed, the cached DLL is missing, or the cached DLL is older than the parent `.ps1` script file.
4. **Optimized CodeDOM Compilation**:
   - Uses parameterless `New-Object Microsoft.CSharp.CSharpCodeProvider` (100% PS 5.1 compatible).
   - Sets `CompilerOptions = "/target:library /optimize+ /debug- /platform:<anycpu|x64>"`.
5. **Zero-Lock Assembly Loading**:
   - Reads the compiled DLL as raw bytes with `[System.IO.File]::ReadAllBytes($dllPath)`.
   - Loads via `[System.Reflection.Assembly]::Load([byte[]]$raw)`.
   - **Result**: The DLL is never locked on disk, allowing clean background cache updates.

---

## Step-by-Step Refactoring Instructions for the AI

1. **Include the Helper**:
   Ensure `Import-OptimizedCSharp.ps1` is dot-sourced at the top of the PowerShell script:
   ```powershell
   . "$PSScriptRoot\Import-OptimizedCSharp.ps1"
   ```

2. **Wrap Type Definition with Type Check Guard**:
   Check if the type already exists before executing the source definition string:
   ```powershell
   if (-not ('MyNamespace.MyClassName' -as [type])) {
       $cSharpCode = @'
       // C# source code here
       namespace MyNamespace {
           public class MyClassName {
               // ...
           }
       }
   '@

       Import-OptimizedCSharp `
           -Source $cSharpCode `
           -ExpectedTypeName 'MyNamespace.MyClassName' `
           -Platform 'AnyCPU' `
           -CallerScriptPath $PSCommandPath
   }
   ```

3. **Handle Additional References**:
   If the C# code references extra assemblies (e.g., `System.Speech.dll`, `PresentationCore.dll`, `System.Windows.Forms.dll`), provide them in `-ReferencedAssemblies`:
   ```powershell
   Import-OptimizedCSharp `
       -Source $cSharpCode `
       -ExpectedTypeName 'MyNamespace.MyClassName' `
       -Platform 'AnyCPU' `
       -ReferencedAssemblies @('System.dll', 'System.Core.dll', 'Microsoft.CSharp.dll', 'System.Windows.Forms.dll') `
       -CallerScriptPath $PSCommandPath
   ```

4. **Preserve Compatibility**:
   - Ensure all PowerShell syntax remains compatible with Windows PowerShell 5.1 (avoid PowerShell 7-only constructs like `??`, `?.`, or `Get-Error`).
   - Retain all C# Win32 P/Invoke signatures and struct definitions exactly as intended.

---

## Reference Implementations
* Helper Implementation: `WebScripts/ps_scripts/Import-OptimizedCSharp.ps1`
* Consumer Examples: `WebScripts/ps_scripts/Stutter-Hunter-IPC.ps1` and `WebScripts/ps_scripts/Stutter-Hunter.ps1`

Please apply this recipe to refactor the provided script now.
