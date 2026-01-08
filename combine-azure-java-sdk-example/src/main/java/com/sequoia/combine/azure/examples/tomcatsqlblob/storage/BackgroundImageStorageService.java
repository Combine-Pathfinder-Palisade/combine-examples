package com.sequoia.combine.azure.examples.tomcatsqlblob.storage;

import java.io.InputStream;
import java.time.OffsetDateTime;

import org.apache.logging.log4j.LogManager;
import org.apache.logging.log4j.Logger;

import com.azure.identity.DefaultAzureCredentialBuilder;
import com.azure.storage.blob.BlobClient;
import com.azure.storage.blob.BlobContainerClient;
import com.azure.storage.blob.BlobServiceClient;
import com.azure.storage.blob.BlobServiceClientBuilder;
import com.azure.storage.blob.models.BlobHttpHeaders;
import com.azure.storage.blob.models.BlobStorageException;

/**
 * Handles storage of shared background images in Azure Blob Storage.
 */
public class BackgroundImageStorageService {

    private static final Logger logger = LogManager.getLogger(BackgroundImageStorageService.class);
    private static final String ENDPOINT_ENV = "BACKGROUND_STORAGE_ENDPOINT";
    private static final String CONTAINER_NAME = "background-images";
    private static final String BASE_NAME = "site-background";

    private final BlobContainerClient containerClient;

    public BackgroundImageStorageService() {
        String endpoint = System.getenv(ENDPOINT_ENV);
        if (endpoint == null || endpoint.isBlank()) {
            throw new IllegalStateException("Environment variable '" + ENDPOINT_ENV + "' must be set to the storage account blob endpoint.");
        }

        BlobServiceClient serviceClient = new BlobServiceClientBuilder()
            .endpoint(endpoint)
            .credential(new DefaultAzureCredentialBuilder().build())
            .buildClient();
        logger.info("Background image uploads configured via endpoint env '{}'.", ENDPOINT_ENV);

        this.containerClient = serviceClient.getBlobContainerClient(CONTAINER_NAME);
        this.containerClient.createIfNotExists();
    }

    public void uploadBackground(String extension, String contentType, InputStream data, long length) {
        BlobClient blobClient = containerClient.getBlobClient(BASE_NAME + extension);
        BlobHttpHeaders headers = new BlobHttpHeaders().setContentType(contentType);
        try {
            blobClient.upload(data, length, true);
            blobClient.setHttpHeaders(headers);
            deleteAlternateExtension(extension);
        } catch (BlobStorageException ex) {
            throw new IllegalStateException("Failed to upload background image to blob storage", ex);
        }
    }

    public String getBackgroundUrl() {
        BlobSelection selection = findLatestBlob();
        if (selection == null) {
            return null;
        }
        long v = selection.lastModified == null ? 0 : selection.lastModified.toInstant().toEpochMilli();
        return "/background-image?v=" + v;
    }

    public BlobContainerClient getContainerClient() {
        return this.containerClient;
    }

    public BlobClient getLatestBackgroundBlob() {
        BlobSelection selection = findLatestBlob();
        return selection == null ? null : selection.client;
    }

    public void deleteBackground() {
        String[] exts = new String[] { ".png", ".jpg" };
        for (String ext : exts) {
            BlobClient blobClient = containerClient.getBlobClient(BASE_NAME + ext);
            try {
                blobClient.deleteIfExists();
            } catch (BlobStorageException ex) {
                logger.warn("Failed to delete background blob {}: {}", blobClient.getBlobName(), ex.getMessage());
            }
        }
    }

    private void deleteAlternateExtension(String extensionKept) {
        String otherExt = extensionKept.equalsIgnoreCase(".png") ? ".jpg" : ".png";
        BlobClient other = containerClient.getBlobClient(BASE_NAME + otherExt);
        try {
            other.deleteIfExists();
        } catch (BlobStorageException ex) {
            logger.warn("Failed to delete old background variant {}: {}", other.getBlobName(), ex.getMessage());
        }
    }

    private BlobSelection findLatestBlob() {
        BlobSelection selection = null;
        String[] exts = new String[] { ".png", ".jpg" };
        for (String ext : exts) {
            BlobClient blobClient = containerClient.getBlobClient(BASE_NAME + ext);
            if (!blobClient.exists()) {
                continue;
            }
            try {
                OffsetDateTime lm = blobClient.getProperties().getLastModified();
                if (selection == null || (lm != null && selection.lastModified != null && lm.isAfter(selection.lastModified)) || (selection.lastModified == null && lm != null)) {
                    selection = new BlobSelection(blobClient, lm);
                }
            } catch (BlobStorageException ex) {
                logger.warn("Unable to read properties for {}: {}", blobClient.getBlobName(), ex.getMessage());
                if (selection == null) {
                    selection = new BlobSelection(blobClient, null);
                }
            }
        }
        return selection;
    }

    private static final class BlobSelection {
        final BlobClient client;
        final OffsetDateTime lastModified;

        BlobSelection(BlobClient client, OffsetDateTime lastModified) {
            this.client = client;
            this.lastModified = lastModified;
        }
    }
}
