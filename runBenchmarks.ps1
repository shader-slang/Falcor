#$rootPath = @("D:\git_repo\faclor-slang\falcor", "D:\git_repo\falcor-preslang-noarea\falcor", "D:\git_repo\falcor-preslang\falcor")
$rootPath = @("D:\git_repo\falcor-preslang\falcor")

$mediaPath = "D:\packman-repo\chk\falcor_media\2.0\Scenes\"

$scenes = @( "Bistro\Bistro_Interior.fscene", "Bistro\Bistro_Exterior.fscene", "SunTemple\SunTemple.fscene")
$sceneNames = @("Bistro_Int", "Bistro_Ext", "SunTemple")

$resultFile = "benchmarkResult_arealight_oldfalcor.txt"
"" > $resultFile
For ($i = 0; $i -lt $scenes.Length; $i++) {
    For ($j = 0; $j -lt $rootPath.Length; $j++) {
        $binDir = $rootPath[$j] + "\Bin\x64\Release\FeatureDemo.exe"
        $sceneFile = $mediaPath + $scenes[$i]
        Set-Content times.txt "<crashed>"
        & $binDir -benchmark -scene $sceneFile | Out-Null
        Add-Content -Path $resultFile -Value $sceneNames[$i] -NoNewline
        Add-Content -Path $resultFile -Value " " -NoNewline
        If ($j -eq 0) {
            Add-Content -Path $resultFile -Value "refactored " -NoNewline
        }
        elseif ($j -eq 1) {
            Add-Content -Path $resultFile -Value "original " -NoNewline
        }
        else {
            Add-Content -Path $resultFile -Value "original+ls " -NoNewline
        }
        $line = Get-Content "times.txt"
        Add-Content -Path $resultFile -Value $line
    }
}