package com.sequoia.combine.azure.examples.tomcatsqlblob;

import java.io.IOException;

import org.apache.logging.log4j.LogManager;
import org.apache.logging.log4j.Logger;

import com.sequoia.combine.azure.examples.tomcatsqlblob.storage.BackgroundImageStorageService;

import jakarta.servlet.ServletException;
import jakarta.servlet.annotation.WebServlet;
import jakarta.servlet.http.HttpServlet;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;

@WebServlet(urlPatterns = "/delete-background")
public class DeleteBackgroundServlet extends HttpServlet {

    private static final Logger logger = LogManager.getLogger(DeleteBackgroundServlet.class);
    private transient BackgroundImageStorageService storageService;

    @Override
    public void init() throws ServletException {
        this.storageService = new BackgroundImageStorageService();
    }

    @Override
    protected void doPost(HttpServletRequest req, HttpServletResponse resp) throws ServletException, IOException {
        try {
            storageService.deleteBackground();
        } catch (RuntimeException ex) {
            logger.warn("Failed to delete background: {}", ex.getMessage());
        }
        String redirect = RedirectHelper.buildRedirectPath(req);
        resp.sendRedirect(redirect);
    }
}
