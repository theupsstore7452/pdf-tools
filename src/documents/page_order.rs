//! Lossless page sequencing: retain content streams, fonts, images and page boxes.
use crate::{
    adapters::{BoundedBytes, UploadFile},
    error::{AppError, AppResult},
    MAX_SOURCE_PDF_PAGES,
};
use lopdf::{dictionary, Dictionary, Document, Object, ObjectId};
use std::collections::HashSet;

pub(crate) fn validate_page_order(order: &[usize], count: usize) -> AppResult<()> {
    if count == 0 || count > MAX_SOURCE_PDF_PAGES || order.len() != count {
        return Err(AppError::bad_request(
            "Page order must contain every source page exactly once.",
        ));
    }
    let mut seen = HashSet::with_capacity(count);
    if order
        .iter()
        .any(|n| *n == 0 || *n > count || !seen.insert(*n))
    {
        return Err(AppError::bad_request(
            "Page order must contain every source page exactly once.",
        ));
    }
    Ok(())
}

pub(crate) fn parse_page_order(value: &str) -> AppResult<Vec<usize>> {
    let order: Vec<usize> = serde_json::from_str(value)
        .map_err(|_| AppError::bad_request("pageOrder must be an array of page numbers."))?;
    if order.is_empty() || order.len() > MAX_SOURCE_PDF_PAGES {
        return Err(AppError::bad_request(
            "Page order has an invalid number of pages.",
        ));
    }
    Ok(order)
}

fn inherited(document: &Document, mut id: ObjectId, key: &[u8]) -> AppResult<Option<Object>> {
    let mut seen = HashSet::new();
    while seen.insert(id) {
        let dict = document
            .get_dictionary(id)
            .map_err(|e| AppError::bad_request_cause("Unreadable PDF page tree.", e))?;
        if let Ok(value) = dict.get(key) {
            return Ok(Some(value.clone()));
        }
        match dict.get(b"Parent").and_then(Object::as_reference) {
            Ok(parent) => id = parent,
            Err(_) => return Ok(None),
        }
    }
    Err(AppError::bad_request("PDF page tree contains a cycle."))
}

pub(crate) fn reorder_pdf(
    file: UploadFile,
    order: &[usize],
    max_bytes: Option<usize>,
) -> AppResult<UploadFile> {
    let mut document = Document::load_mem(&file.bytes)
        .map_err(|e| AppError::bad_request_cause("Could not read PDF pages to organize.", e))?;
    let pages = document.get_pages().into_values().collect::<Vec<_>>();
    validate_page_order(order, pages.len())?;
    if order.iter().copied().eq(1..=pages.len()) {
        return Ok(file);
    }
    let root = document.new_object_id();
    for id in &pages {
        let mut values = Dictionary::new();
        // Materialize inherited geometry/resources before replacing the parent.
        for key in [b"MediaBox".as_slice(), b"CropBox", b"Resources", b"Rotate"] {
            if let Some(value) = inherited(&document, *id, key)? {
                values.set(key, value);
            }
        }
        let page = document
            .get_dictionary_mut(*id)
            .map_err(|e| AppError::bad_request_cause("Unreadable PDF page.", e))?;
        for (key, value) in values.iter() {
            page.set(key.clone(), value.clone());
        }
        page.set("Parent", root);
    }
    document.objects.insert(
        root,
        Object::Dictionary(dictionary! {"Type"=>"Pages", "Count"=>pages.len() as i64,
        "Kids"=>order.iter().map(|n| Object::Reference(pages[n-1])).collect::<Vec<_>>()}),
    );
    document
        .catalog_mut()
        .map_err(|e| AppError::bad_request_cause("Unreadable PDF catalog.", e))?
        .set("Pages", root);
    let mut output =
        BoundedBytes::new(super::estimated_lopdf_output_capacity(&document), max_bytes);
    let saved = document.save_to(&mut output);
    Ok(UploadFile {
        filename: file.filename,
        bytes: output
            .finish(saved, "Could not save organized pages.")?
            .into(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use lopdf::Stream;
    fn source() -> UploadFile {
        let mut document = Document::with_version("1.7");
        let pages = document.new_object_id();
        let mut ids = vec![];
        for n in 1..=3 {
            let content = document.add_object(Stream::new(
                Dictionary::new(),
                format!("% CONTENT {n}\n").into_bytes(),
            ));
            ids.push(document.add_object(dictionary!{"Type"=>"Page","Parent"=>pages,"Contents"=>content,"PdfToolsSourcePage"=>n}));
        }
        document.objects.insert(pages,Object::Dictionary(dictionary!{"Type"=>"Pages","Count"=>3,"Kids"=>ids.iter().map(|id|Object::Reference(*id)).collect::<Vec<_>>(),
            "MediaBox"=>vec![0.into(),0.into(),216.into(),144.into()],"CropBox"=>vec![9.into(),9.into(),207.into(),135.into()],"Rotate"=>90,"Resources"=>Dictionary::new()}));
        let root = document.add_object(dictionary! {"Type"=>"Catalog","Pages"=>pages});
        document.trailer.set("Root", root);
        let mut bytes = vec![];
        document.save_to(&mut bytes).unwrap();
        UploadFile {
            filename: "test.pdf".into(),
            bytes: bytes.into(),
        }
    }
    #[test]
    fn permutations_reject_missing_repeated_zero_and_out_of_range_pages() {
        for order in [
            vec![],
            vec![1, 2],
            vec![1, 1, 3],
            vec![0, 2, 3],
            vec![1, 2, 4],
        ] {
            assert!(validate_page_order(&order, 3).is_err());
        }
        assert!(validate_page_order(&[3, 1, 2], 3).is_ok());
        assert!(parse_page_order("[1,-2]").is_err());
    }
    #[test]
    fn identity_order_reuses_original_bytes_and_other_orders_keep_content_and_inheritance() {
        let file = source();
        let identity = reorder_pdf(file.clone(), &[1, 2, 3], None).unwrap();
        assert_eq!(identity.bytes.as_ptr(), file.bytes.as_ptr());
        let ordered = reorder_pdf(file.clone(), &[3, 1, 2], None).unwrap();
        let document = Document::load_mem(&ordered.bytes).unwrap();
        for (id, original) in document.get_pages().into_values().zip([3, 1, 2]) {
            let page = document.get_dictionary(id).unwrap();
            assert_eq!(
                page.get(b"PdfToolsSourcePage").unwrap().as_i64().unwrap(),
                original
            );
            assert_eq!(page.get(b"Rotate").unwrap().as_i64().unwrap(), 90);
            assert!(page.has(b"MediaBox") && page.has(b"CropBox") && page.has(b"Resources"));
            assert_eq!(
                document
                    .get_object(page.get(b"Contents").unwrap().as_reference().unwrap())
                    .unwrap()
                    .as_stream()
                    .unwrap()
                    .content,
                format!("% CONTENT {original}\n").as_bytes()
            );
        }
        assert!(matches!(
            reorder_pdf(file, &[3, 1, 2], Some(1)),
            Err(AppError::PayloadTooLarge(_))
        ));
    }
}
