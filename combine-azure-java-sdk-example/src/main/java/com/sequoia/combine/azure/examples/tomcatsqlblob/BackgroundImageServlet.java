package com.sequoia.combine.azure.examples.tomcatsqlblob;

import java.io.IOException;
import java.io.OutputStream;
import java.time.OffsetDateTime;

import org.apache.logging.log4j.LogManager;
import org.apache.logging.log4j.Logger;

import com.azure.storage.blob.BlobClient;
import com.azure.storage.blob.models.BlobProperties;
import com.azure.storage.blob.models.BlobStorageException;
import com.sequoia.combine.azure.examples.tomcatsqlblob.storage.BackgroundImageStorageService;

import jakarta.servlet.ServletException;
import jakarta.servlet.annotation.WebServlet;
import jakarta.servlet.http.HttpServlet;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;

@WebServlet(urlPatterns = "/background-image")
public class BackgroundImageServlet extends HttpServlet {

    private static final Logger logger = LogManager.getLogger(BackgroundImageServlet.class);
    private transient BackgroundImageStorageService storageService;

    @Override
    public void init() throws ServletException {
        this.storageService = new BackgroundImageStorageService();
    }

    @Override
    protected void doGet(HttpServletRequest req, HttpServletResponse resp) throws ServletException, IOException {
        BlobClient blobClient = storageService.getLatestBackgroundBlob();
        if (blobClient == null) {
            resp.sendError(HttpServletResponse.SC_NOT_FOUND);
            return;
        }

        try {
            BlobProperties props = blobClient.getProperties();
            OffsetDateTime lastModified = props.getLastModified();
            String etag = props.getETag();

            long lastModifiedMillis = lastModified == null ? -1 : lastModified.toInstant().toEpochMilli();
            String ifNoneMatch = req.getHeader("If-None-Match");
            if (etag != null && etag.equals(ifNoneMatch)) {
                resp.setStatus(HttpServletResponse.SC_NOT_MODIFIED);
                return;
            }

            long ifModifiedSince = req.getDateHeader("If-Modified-Since");
            if (lastModifiedMillis > 0 && ifModifiedSince >= 0 && lastModifiedMillis / 1000 <= ifModifiedSince / 1000) {
                resp.setStatus(HttpServletResponse.SC_NOT_MODIFIED);
                return;
            }

            resp.setContentType(props.getContentType());
            if (etag != null) {
                resp.setHeader("ETag", etag);
            }
            if (lastModifiedMillis > 0) {
                resp.setDateHeader("Last-Modified", lastModifiedMillis);
            }
            resp.setHeader("Cache-Control", "public, max-age=31536000, immutable");
            try (OutputStream os = resp.getOutputStream()) {
                blobClient.downloadStream(os);
            }
        } catch (BlobStorageException ex) {
            logger.warn("Failed to stream background: {}", ex.getMessage());
            resp.sendError(HttpServletResponse.SC_INTERNAL_SERVER_ERROR, "Failed to stream background image");
        }
    }
}
