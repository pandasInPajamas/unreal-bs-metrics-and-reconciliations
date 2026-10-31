// Paste into a Blank Query named fnLoadCsv.
// Needs a Text parameter named DataRoot, e.g.
//   https://raw.githubusercontent.com/<your-user>/unreal-bs-does-it-tie/main/data/
// RelativePath keeps the base URL static, so the Power BI service can refresh it.
(fileName as text) as table =>
let
    Raw      = Web.Contents(DataRoot, [RelativePath = fileName]),
    Csv      = Csv.Document(Raw, [Delimiter = ",", Encoding = 65001, QuoteStyle = QuoteStyle.Csv]),
    Promoted = Table.PromoteHeaders(Csv, [PromoteAllScalars = true])
in
    Promoted
