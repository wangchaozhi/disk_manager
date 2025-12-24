use axum::{
    extract::{Multipart, Json, Query, DefaultBodyLimit},
    http::{StatusCode, Method, header},
    response::{IntoResponse, Json as AxumJson},
    body::Body,
    routing::{get, post},
    Router,
};
use serde::Deserialize;
use std::{net::SocketAddr, path::PathBuf};
use tower_http::cors::{Any, CorsLayer};
use tokio::fs;
use tokio_util::io::ReaderStream;

#[tokio::main]
async fn main() {
    tracing_subscriber::fmt::init();

    let storage_path = PathBuf::from("storage");
    if !storage_path.exists() {
        fs::create_dir_all(&storage_path).await.unwrap();
    }

    let cors = CorsLayer::new()
        .allow_origin(Any)
        .allow_methods([Method::GET, Method::POST, Method::DELETE])
        .allow_headers(Any);

    let app = Router::new()
        .route("/", get(root))
        .route("/create_folder", post(create_folder))
        .route("/upload", post(upload_file))
        .route("/list", get(list_files))
        .route("/download", get(download_file))
        .route("/delete", axum::routing::delete(delete_file))
        .layer(DefaultBodyLimit::max(1024 * 1024 * 1024)) // 1GB limit
        .layer(cors);

    let addr = SocketAddr::from(([127, 0, 0, 1], 3000));
    println!("listening on {}", addr);
    let listener = tokio::net::TcpListener::bind(addr).await.unwrap();
    axum::serve(listener, app).await.unwrap();
}

async fn root() -> &'static str {
    "Disk Manager Backend Running"
}

// Helper to sanitize and resolve path
fn resolve_path(subpath: Option<String>) -> Result<PathBuf, String> {
    let base = PathBuf::from("storage");
    let sub = subpath.unwrap_or_default();
    
    // Simple sanitization
    if sub.contains("..") {
        return Err("Invalid path".to_string());
    }
    
    // Remove leading slashes to append correctly
    let clean_sub = sub.trim_start_matches('/');
    Ok(base.join(clean_sub))
}

#[derive(Deserialize)]
struct PathReq {
    path: String,
}

#[derive(Deserialize)]
struct OptionalPathReq {
    path: Option<String>,
}

async fn create_folder(Json(payload): Json<PathReq>) -> impl IntoResponse {
    match resolve_path(Some(payload.path)) {
        Ok(path) => {
            if path.exists() {
                return (StatusCode::CONFLICT, "Folder or file already exists").into_response();
            }
            match fs::create_dir_all(path).await {
                Ok(_) => (StatusCode::OK, "Folder created").into_response(),
                Err(e) => (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()).into_response(),
            }
        },
        Err(e) => (StatusCode::BAD_REQUEST, e).into_response(),
    }
}

async fn upload_file(
    Query(params): Query<OptionalPathReq>,
    mut multipart: Multipart
) -> impl IntoResponse {
    let target_dir = match resolve_path(params.path) {
        Ok(p) => p,
        Err(e) => return (StatusCode::BAD_REQUEST, e).into_response(),
    };

    while let Some(field) = multipart.next_field().await.unwrap() {
        let file_name = if let Some(name) = field.file_name() {
            name.to_string()
        } else {
            continue;
        };

        if file_name.is_empty() { continue; }

        let data = match field.bytes().await {
            Ok(d) => d,
            Err(e) => return (StatusCode::BAD_REQUEST, e.to_string()).into_response(),
        };

        let path = target_dir.join(file_name);
        
        if let Err(e) = fs::write(path, data).await {
             return (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()).into_response();
        }
    }

    (StatusCode::OK, "File uploaded").into_response()
}

async fn list_files(Query(params): Query<OptionalPathReq>) -> impl IntoResponse {
    let path = match resolve_path(params.path) {
        Ok(p) => p,
        Err(e) => return (StatusCode::BAD_REQUEST, e).into_response(),
    };
    
    let mut entries = Vec::new();
    
    if let Ok(mut read_dir) = fs::read_dir(path).await {
         while let Ok(Some(entry)) = read_dir.next_entry().await {
             let name = entry.file_name().to_string_lossy().to_string();
             let is_dir = entry.file_type().await.map(|ft| ft.is_dir()).unwrap_or(false);
             entries.push(FileEntry { name, is_dir });
         }
    }
    
    AxumJson(entries).into_response()
}

async fn download_file(Query(params): Query<PathReq>) -> impl IntoResponse {
    let path = match resolve_path(Some(params.path)) {
        Ok(p) => p,
        Err(e) => return (StatusCode::BAD_REQUEST, e).into_response(),
    };

    if !path.exists() {
        return (StatusCode::NOT_FOUND, "Not found").into_response();
    }

    if path.is_file() {
        let file = match fs::File::open(&path).await {
            Ok(f) => f,
            Err(_) => return (StatusCode::INTERNAL_SERVER_ERROR, "Could not open file").into_response(),
        };

        let stream = ReaderStream::new(file);
        let body = Body::from_stream(stream);

        let filename = path.file_name().unwrap().to_string_lossy().to_string();
        
        let headers = [
            (header::CONTENT_TYPE, "application/octet-stream"),
            (header::CONTENT_DISPOSITION, &format!("attachment; filename=\"{}\"", filename)),
        ];

        return (headers, body).into_response();
    }

    // Is directory: Zip it
    let path_clone = path.clone();
    let zip_buffer = tokio::task::spawn_blocking(move || {
        use std::io::Write;
        use walkdir::WalkDir;
        
        let mut zip = zip::ZipWriter::new(std::io::Cursor::new(Vec::new()));
        let options = zip::write::SimpleFileOptions::default()
            .compression_method(zip::CompressionMethod::Stored);

        let parent_dir = path_clone.parent().unwrap_or(&path_clone);

        for entry in WalkDir::new(&path_clone) {
            let entry = entry.map_err(|e| e.to_string())?;
            let path = entry.path();
            
            if path.is_file() {
                let name = path.strip_prefix(parent_dir).unwrap().to_str().unwrap();
                
                zip.start_file(name, options).map_err(|e| e.to_string())?;
                let mut f = std::fs::File::open(path).map_err(|e| e.to_string())?;
                let mut content = Vec::new(); 
                use std::io::Read;
                f.read_to_end(&mut content).map_err(|e| e.to_string())?;
                zip.write_all(&content).map_err(|e| e.to_string())?;
            }
        }
        let cursor = zip.finish().map_err(|e| e.to_string())?;
        Ok::<Vec<u8>, String>(cursor.into_inner())
    }).await.unwrap();

    match zip_buffer {
        Ok(buffer) => {
            let filename = format!("{}.zip", path.file_name().unwrap().to_string_lossy());
            let headers = [
                (header::CONTENT_TYPE, "application/zip"),
                (header::CONTENT_DISPOSITION, &format!("attachment; filename=\"{}\"", filename)),
            ];
             (headers, buffer).into_response()
        },
        Err(e) => (StatusCode::INTERNAL_SERVER_ERROR, e).into_response(),
    }
}

#[derive(serde::Serialize)]
struct FileEntry {
    name: String,
    is_dir: bool,
}

async fn delete_file(Query(params): Query<PathReq>) -> impl IntoResponse {
    let path = match resolve_path(Some(params.path)) {
        Ok(p) => p,
        Err(e) => return (StatusCode::BAD_REQUEST, e).into_response(),
    };

    if !path.exists() {
        return (StatusCode::NOT_FOUND, "Not found").into_response();
    }

    let result = if path.is_dir() {
        fs::remove_dir_all(path).await
    } else {
        fs::remove_file(path).await
    };

    match result {
        Ok(_) => (StatusCode::OK, "Deleted").into_response(),
        Err(e) => (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()).into_response(),
    }
}
