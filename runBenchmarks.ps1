$rootPath = "D:\git_repo\faclor-slang\falcor"
$mediaPath = $rootPath + "\Media\Scenes\"
$binDir = $rootPath + "\Bin\x64\Release\FeatureDemo.exe"
$scenes = @("Bistro\Bistro_Interior.fscene", "Bistro\Bistro_Exterior.fscene", "SunTemple\SunTemple.fscene")
$sceneNames = @("Bistro_Int", "Bistro_Ext", "SunTemple")

"" > 'benchmarkResult.txt'

For ($i = 0; $i -lt $scenes.Length; $i++) {
    $sceneFile = $mediaPath + $scenes[$i]
    & $binDir -benchmark -scene $sceneFile | Out-Null
    $sceneNames[$i] >> 'benchmarkResult.txt'
    " " >> 'benchmarkResult.txt'
    Get-Content "times.txt" >> 'benchmarkResult.txt'
    "`n" >> 'benchmarkResult.txt'
}