use super::*;

#[tokio::test]
#[serial]
async fn yard_sign_places_vector_art_on_every_bleed_sized_page() {
    let state = state_or_skip().unwrap();
    // A 270 x 162 pt original on a 540 x 486 pt full-bleed sheet.
    for (mode, matrix) in [
        ("fit", [2., 0., 0., 2., 0., 81.]),
        ("fill", [3., 0., 0., 3., -135., 0.]),
        ("stretch", [2., 0., 0., 3., 0., 0.]),
    ] {
        let response = send(
            state.clone(),
            multipart_request(
                "/api/yard-sign",
                vec![
                    text_part("width", "7"),
                    text_part("height", "6.25"),
                    text_part("mode", mode),
                    upload_part("file", "Art.pdf", sample_colored_trim_pdf_bytes(2)),
                ],
            ),
        )
        .await;
        assert_eq!(response.status(), StatusCode::OK);
        assert_eq!(response.headers()[header::CONTENT_TYPE], "application/pdf");
        let doc = LoDocument::load_mem(&body_bytes(response).await).unwrap();
        let pages = doc.get_pages();
        assert_eq!(pages.len(), 2);
        for id in pages.into_values() {
            let page = doc.get_dictionary(id).unwrap();
            for (key, expected) in [
                ("MediaBox", [0., 0., 540., 486.]),
                ("CropBox", [0., 0., 540., 486.]),
                ("BleedBox", [0., 0., 540., 486.]),
                ("TrimBox", [18., 18., 522., 468.]),
            ] {
                let bounds = page.get(key.as_bytes()).unwrap().as_array().unwrap();
                assert_eq!(numbers(bounds), expected);
            }
            let ops = doc.get_and_decode_page_content(id).unwrap().operations;
            assert_eq!(
                numbers(&ops.iter().find(|op| op.operator == "cm").unwrap().operands),
                matrix
            );
            let draw = ops.iter().find(|op| op.operator == "Do").unwrap();
            let xobjects = page
                .get(b"Resources")
                .unwrap()
                .as_dict()
                .unwrap()
                .get(b"XObject")
                .unwrap()
                .as_dict()
                .unwrap();
            let form = doc
                .get_object(
                    xobjects
                        .get(draw.operands[0].as_name().unwrap())
                        .unwrap()
                        .as_reference()
                        .unwrap(),
                )
                .unwrap()
                .as_stream()
                .unwrap();
            assert!(form
                .get_plain_content()
                .unwrap()
                .windows(8)
                .any(|bytes| bytes == b"1 0 0 rg"));
        }
    }
}
fn numbers(objects: &[Object]) -> Vec<f32> {
    objects.iter().map(|o| o.as_float().unwrap()).collect()
}

#[tokio::test]
#[serial]
async fn yard_sign_rejects_invalid_fields_and_non_pdf_input() {
    let state = state_or_skip().unwrap();
    for (w, h, mode, bytes) in [
        ("NaN", "18", "fill", sample_colored_trim_pdf_bytes(1)),
        ("24", "0", "fit", sample_colored_trim_pdf_bytes(1)),
        ("24", "18", "crop", sample_colored_trim_pdf_bytes(1)),
        ("24", "18", "fit", sample_png_bytes()),
    ] {
        let response = send(
            state.clone(),
            multipart_request(
                "/api/yard-sign",
                vec![
                    text_part("width", w),
                    text_part("height", h),
                    text_part("mode", mode),
                    upload_part("file", "art.pdf", bytes),
                ],
            ),
        )
        .await;
        assert_eq!(response.status(), StatusCode::BAD_REQUEST);
    }
}

#[tokio::test]
#[serial]
async fn yard_sign_proof_matches_export_pixels_on_rotated_cropped_page() {
    let state = state_or_skip().unwrap();
    let mut source = LoDocument::load_mem(&sample_colored_trim_pdf_bytes(2)).unwrap();
    let page = source.get_dictionary_mut(source.get_pages()[&2]).unwrap();
    page.set("Rotate", 90);
    page.set("CropBox", vec![7.into(), 3.into(), 268.into(), 160.into()]);
    let mut bytes = Vec::new();
    source.save_to(&mut bytes).unwrap();
    let prepare = send(
        state.clone(),
        multipart_request(
            "/api/yard-sign/sources",
            vec![upload_part("file", "art.pdf", bytes.clone())],
        ),
    )
    .await;
    assert_eq!(prepare.status(), StatusCode::OK);
    let session: serde_json::Value = serde_json::from_slice(&body_bytes(prepare).await).unwrap();
    let route = format!(
        "/api/yard-sign/sources/{}/previews",
        session["sourceId"].as_str().unwrap()
    );
    for mode in ["fit", "fill", "stretch"] {
        let response = send(
            state.clone(),
            json_request(
                &route,
                serde_json::json!({"pageNumbers":[2],"mode":mode,"width":"9.5","height":"7"}),
            ),
        )
        .await;
        assert_eq!(response.status(), StatusCode::OK);
        let batch = preview_batch_pages(&body_bytes(response).await);
        let proof = image::load_from_memory(&batch[&2]).unwrap().to_rgb8();
        assert_eq!(proof.dimensions(), (480, 360));
        let export = send(
            state.clone(),
            multipart_request(
                "/api/yard-sign",
                vec![
                    upload_part("file", "art.pdf", bytes.clone()),
                    text_part("width", "9.5"),
                    text_part("height", "7"),
                    text_part("mode", mode),
                ],
            ),
        )
        .await;
        let pdfium = state.pdfium();
        let doc = pdfium
            .load_pdf_from_byte_vec(body_bytes(export).await, None)
            .unwrap();
        let actual = doc
            .pages()
            .get(1)
            .unwrap()
            .render_with_config(
                &PdfRenderConfig::new()
                    .set_target_width(480)
                    .set_maximum_height(360)
                    .use_print_quality(true)
                    .force_half_tone(true),
            )
            .unwrap()
            .as_image()
            .unwrap()
            .to_rgb8();
        assert!(actual.pixels().any(|pixel| pixel[0] < 200));
        assert!(actual == proof, "{mode}: proof differs from exported page");
    }
    let invalid = send(
        state,
        json_request(
            &route,
            serde_json::json!({"pageNumbers":[3],"mode":"fit","width":"24","height":"18"}),
        ),
    )
    .await;
    assert_eq!(invalid.status(), StatusCode::BAD_REQUEST);
}
