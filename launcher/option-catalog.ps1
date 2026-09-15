# Return fresh metadata objects so settings windows cannot share mutable state.
function Get-ScrcpyOptionCatalog {
    $catalogPath = Join-Path $PSScriptRoot 'option-catalog.json'
    $catalog = Get-Content -LiteralPath $catalogPath -Raw | ConvertFrom-Json
    return $catalog
}
