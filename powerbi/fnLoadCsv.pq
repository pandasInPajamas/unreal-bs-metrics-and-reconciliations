// Paste into a Blank Query named fnLoadCsv.
// Needs a Text parameter named DataRoot:
//   https://raw.githubusercontent.com/pandasInPajamas/unreal-bs-metrics-and-reconciliations/main/data/
// RelativePath keeps the base URL static, so the Power BI service can refresh it.
// Empty cells become null, so typed columns (dates, numbers) don't error.
(fileName as text) as table =>
let
    Raw      = Web.Contents(DataRoot, [RelativePath = fileName]),
    Csv      = Csv.Document(Raw, [Delimiter = ",", Encoding = 65001, QuoteStyle = QuoteStyle.Csv]),
    Promoted = Table.PromoteHeaders(Csv, [PromoteAllScalars = true]),
    Nulls    = Table.ReplaceValue(Promoted, "", null, Replacer.ReplaceValue, Table.ColumnNames(Promoted))
in
    Nulls
