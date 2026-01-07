package com.sequoia.combine.azure.examples.tomcatsqlblob;

import java.io.IOException;
import java.io.InputStream;

import org.apache.logging.log4j.LogManager;
import org.apache.logging.log4j.Logger;

import com.sequoia.combine.azure.examples.tomcatsqlblob.storage.BackgroundImageStorageService;

import jakarta.servlet.ServletException;
import jakarta.servlet.annotation.MultipartConfig;
import jakarta.servlet.annotation.WebServlet;
import jakarta.servlet.http.HttpServlet;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import jakarta.servlet.http.Part;

@WebServlet(urlPatterns = "/upload-background")
@MultipartConfig(maxFileSize = BackgroundImageUploadServlet.MAX_FILE_SIZE_BYTES, maxRequestSize = BackgroundImageUploadServlet.MAX_REQUEST_SIZE_BYTES)
public class BackgroundImageUploadServlet extends HttpServlet {

    static final long MAX_FILE_SIZE_BYTES = 5 * 1024 * 1024; // 5 MB
    static final long MAX_REQUEST_SIZE_BYTES = 6 * 1024 * 1024; // Allow small overhead

    private static final Logger logger = LogManager.getLogger(BackgroundImageUploadServlet.class);

    private BackgroundImageStorageService storageService;

    @Override
    public void init() throws ServletException {
        try {
            this.storageService = new BackgroundImageStorageService();
        } catch (RuntimeException ex) {
            throw new ServletException("Failed to initialize storage client", ex);
        }
    }

    @Override
    protected void doPost(HttpServletRequest req, HttpServletResponse resp) throws ServletException, IOException {
        logger.info("POST /upload-background");

        Part imagePart;
        try {
            imagePart = req.getPart("backgroundImage");
        } catch (IllegalStateException ex) {
            resp.sendError(HttpServletResponse.SC_REQUEST_ENTITY_TOO_LARGE, "Upload exceeds allowed size.");
            return;
        }

        if (imagePart == null || imagePart.getSize() <= 0) {
            resp.sendError(HttpServletResponse.SC_BAD_REQUEST, "No image was uploaded.");
            return;
        }

        if (imagePart.getSize() > MAX_FILE_SIZE_BYTES) {
            resp.sendError(HttpServletResponse.SC_REQUEST_ENTITY_TOO_LARGE, "Image exceeds 5 MB limit.");
            return;
        }

        String contentType = imagePart.getContentType();
        String extension = resolveExtension(contentType);
        if (extension == null) {
            resp.sendError(HttpServletResponse.SC_BAD_REQUEST, "Only PNG and JPG images are supported.");
            return;
        }

        try (InputStream data = imagePart.getInputStream()) {
            storageService.uploadBackground(extension, contentType, data, imagePart.getSize());
        } catch (IllegalStateException ex) {
            logger.error("Failed to upload background image", ex);
            resp.sendError(HttpServletResponse.SC_INTERNAL_SERVER_ERROR, "Failed to upload background image. Check storage endpoint configuration and permissions.");
            return;
        }

        String redirect = RedirectHelper.buildRedirectPath(req);
        resp.sendRedirect(redirect);
    }

    private String resolveExtension(String contentType) {
        if (contentType == null) {
            return null;
        }
        if (contentType.equalsIgnoreCase("image/png")) {
            return ".png";
        }
        if (contentType.equalsIgnoreCase("image/jpeg") || contentType.equalsIgnoreCase("image/jpg")) {
            return ".jpg";
        }
        return null;
    }
}
