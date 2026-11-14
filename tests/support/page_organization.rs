use super::*;
fn labeled_pdf(labels: &[&str]) -> Vec<u8> {
    let mut doc = LoDocument::with_version("1.7");
    let pages = doc.new_object_id();
    let mut ids = vec![];
    let font =
        doc.add_object(dictionary! {"Type"=>"Font","Subtype"=>"Type1","BaseFont"=>"Helvetica"});
    for label in labels {
        let content = doc.add_object(Stream::new(
            Dictionary::new(),
            format!("BT /F1 18 Tf 18 72 Td ({label}) Tj ET").into_bytes(),
        ));
        ids.push(doc.add_object(dictionary!{"Type"=>"Page","Parent"=>pages,"MediaBox"=>vec![0.into(),0.into(),216.into(),144.into()],"Contents"=>content,"Resources"=>dictionary!{"Font"=>dictionary!{"F1"=>font}}}));
    }
    doc.objects.insert(pages,Object::Dictionary(dictionary!{"Type"=>"Pages","Count"=>ids.len() as i64,"Kids"=>ids.into_iter().map(Object::Reference).collect::<Vec<_>>()}));
    let root = doc.add_object(dictionary! {"Type"=>"Catalog","Pages"=>pages});
    doc.trailer.set("Root", root);
    let mut bytes = vec![];
    doc.save_to(&mut bytes).unwrap();
    bytes
}
fn text_pages(bytes: &[u8]) -> Vec<String> {
    let doc = LoDocument::load_mem(bytes).unwrap();
    doc.get_pages()
        .keys()
        .map(|n| doc.extract_text(&[*n]).unwrap().trim().to_string())
        .collect()
}
#[tokio::test]
#[serial(pdfium)]
async fn page_order_drives_merge_extract_images_and_prepared_impose_sources() {
    let Some(state) = state_or_skip() else { return };
    let merged = send(
        state.clone(),
        multipart_request(
            "/merge",
            vec![
                text_part("pageOrder", "[3,1,4,2]"),
                upload_part("file", "one.pdf", labeled_pdf(&["ONE", "TWO"])),
                upload_part("file", "two.pdf", labeled_pdf(&["THREE", "FOUR"])),
            ],
        ),
    )
    .await;
    assert_eq!(merged.status(), StatusCode::OK);
    assert_eq!(
        text_pages(&body_bytes(merged).await),
        ["THREE", "ONE", "FOUR", "TWO"]
    );
    let extracted = send(
        state.clone(),
        multipart_request(
            "/split",
            vec![
                text_part("pageOrder", "[3,1,2]"),
                text_part("pages", "1-2"),
                text_part("outputMode", "combined"),
                upload_part("file", "source.pdf", labeled_pdf(&["ONE", "TWO", "THREE"])),
            ],
        ),
    )
    .await;
    assert_eq!(extracted.status(), StatusCode::OK);
    assert_eq!(text_pages(&body_bytes(extracted).await), ["THREE", "ONE"]);
    for order in ["[1,1,3]", "[0,2,3]", "[1,2]", "[1,2,4]"] {
        let rejected = send(
            state.clone(),
            multipart_request(
                "/split",
                vec![
                    text_part("pageOrder", order),
                    text_part("pages", "all"),
                    upload_part("file", "source.pdf", labeled_pdf(&["ONE", "TWO", "THREE"])),
                ],
            ),
        )
        .await;
        assert_eq!(rejected.status(), StatusCode::BAD_REQUEST);
    }
    let prepared = send(
        state.clone(),
        multipart_request(
            "/gang-up/sources",
            vec![
                text_part("pageOrder", "[3,1,2]"),
                upload_part("file", "source.pdf", labeled_pdf(&["ONE", "TWO", "THREE"])),
            ],
        ),
    )
    .await;
    assert_eq!(prepared.status(), StatusCode::ACCEPTED);
    let id = body_text(prepared).await;
    wait_for_job_status(state.clone(), &id, "done").await;
    let result = send(state.clone(), get_request(&format!("/jobs/{id}/download"))).await;
    let source: serde_json::Value = serde_json::from_slice(&body_bytes(result).await).unwrap();
    assert_eq!(
        source["analysis"]["sourcePages"][0]["originalPageNumber"],
        3
    );
    let source_id = source["sourceId"].as_str().unwrap();
    let reordered = send(
        state.clone(),
        json_request(
            &format!("/gang-up/sources/{source_id}/order"),
            serde_json::json!({"pageOrder":[2,3,1]}),
        ),
    )
    .await;
    assert_eq!(reordered.status(), StatusCode::OK);
    let next: serde_json::Value = serde_json::from_slice(&body_bytes(reordered).await).unwrap();
    assert_eq!(next["analysis"]["sourcePages"][0]["originalPageNumber"], 1);
    // Raw page thumbnails are bounded independently of physical source size.
    let workspace = send(
        state.clone(),
        multipart_request(
            "/pdf/workspaces",
            vec![upload_part(
                "file",
                "source.pdf",
                labeled_pdf(&["ONE", "TWO", "THREE"]),
            )],
        ),
    )
    .await;
    assert_eq!(workspace.status(), StatusCode::ACCEPTED);
    let id = body_text(workspace).await;
    wait_for_job_status(state.clone(), &id, "done").await;
    let result = send(state.clone(), get_request(&format!("/jobs/{id}/download"))).await;
    let source: serde_json::Value = serde_json::from_slice(&body_bytes(result).await).unwrap();
    let result = send(
        state.clone(),
        json_request(
            &format!(
                "/pdf/workspaces/{}/previews",
                source["sourceId"].as_str().unwrap()
            ),
            serde_json::json!({"pageNumbers":[3,1]}),
        ),
    )
    .await;
    assert_eq!(result.status(), StatusCode::OK);
    for png in preview_batch_pages(&body_bytes(result).await).values() {
        let image = image::load_from_memory(png).unwrap();
        assert!(image.width() <= 240 && image.height() <= 320);
    }
}
