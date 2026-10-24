"""06 | Massachusetts regulations (CMR): extract text from the mass.gov PDFs.

Manual step first: download each regulation PDF from mass.gov into data/ma_regulations/,
named like 105-CMR-590.pdf. The official version is the purchased print edition;
these PDFs are an informational copy.
Output: data/ma_regulations/ma_regulations_text.json
"""
from pypdf import PdfReader

from common import data_dir, rel, save_json


def main():
    folder = data_dir("ma_regulations")
    pdfs = sorted(folder.glob("*.pdf"))
    if not pdfs:
        raise SystemExit(f"No PDFs in {rel(folder)}. Download them from mass.gov first.")

    records = []
    for pdf in pdfs:
        pages = [(p.extract_text() or "") for p in PdfReader(pdf).pages]
        text = "\n".join(pages)
        citation = pdf.stem.replace("-", " ")  # "105-CMR-590" -> "105 CMR 590"
        records.append({"citation": citation, "source_file": pdf.name,
                        "pages": len(pages), "characters": len(text), "text": text})
        empty = sum(1 for p in pages if not p.strip())
        print(f"{citation:<12} {len(pages):>4} pages  {len(text):>9,} characters  {empty} empty pages")

    out_file = save_json(folder / "ma_regulations_text.json", records)
    print(f"\nSaved text of {len(records)} regulations to {rel(out_file)}")


if __name__ == "__main__":
    main()
