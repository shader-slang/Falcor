$rootPath = @("D:\git_repo\faclor-slang\falcor", "D:\git_repo\falcor-preslang\falcor")
$mediaPath = $rootPath[0] + "\Media\Scenes\"

$scenes = @("bumpyplane.fscene", "Bistro\Bistro_Interior.fscene", "Bistro\Bistro_Exterior.fscene", "SunTemple\SunTemple.fscene")
$sceneNames = @("BumpyPlane", "Bistro_Int", "Bistro_Ext", "SunTemple")

#$scenes = @("Bistro\Bistro_Exterior.fscene")
#$sceneNames = @("Bistro_Ext")

"" > benchmarkResult.txt
For ($i = 0; $i -lt $scenes.Length; $i++) {
    For ($j = 0; $j -lt $rootPath.Length; $j++) {
        $binDir = $rootPath[$j] + "\Bin\x64\Release\FeatureDemo.exe"
        $sceneFile = $mediaPath + $scenes[$i]
        Set-Content times.txt "<crashed>"
        & $binDir -benchmark -scene $sceneFile | Out-Null
        Add-Content -Path benchmarkResult.txt -Value $sceneNames[$i] -NoNewline
        Add-Content -Path benchmarkResult.txt -Value " " -NoNewline
        If ($j -eq 0) {
            Add-Content -Path benchmarkResult.txt -Value "refactored " -NoNewline
        }
        else {
            Add-Content -Path benchmarkResult.txt -Value "original " -NoNewline
        }
        $line = Get-Content "times.txt"
        Add-Content -Path benchmarkResult.txt -Value $line
    }
}