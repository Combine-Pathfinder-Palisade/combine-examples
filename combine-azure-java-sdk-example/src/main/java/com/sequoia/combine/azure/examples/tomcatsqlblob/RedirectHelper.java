package com.sequoia.combine.azure.examples.tomcatsqlblob;

import jakarta.servlet.http.HttpServletRequest;

/**
 * Builds safe redirects back to the calendar view while keeping month/year/selected context.
 */
public final class RedirectHelper {
    private RedirectHelper() {
    }

    public static String buildRedirectPath(HttpServletRequest req) {
        String ctx = req.getContextPath();
        String base = (ctx != null && !ctx.isEmpty()) ? ctx : "";

        String year = req.getParameter("year");
        String month = req.getParameter("month");
        String selected = req.getParameter("selected");

        StringBuilder path = new StringBuilder();
        path.append(base).append("/");

        boolean hasQuery = false;
        hasQuery = appendQuery(path, "year", year, hasQuery);
        hasQuery = appendQuery(path, "month", month, hasQuery);
        appendQuery(path, "selected", selected, hasQuery);

        return path.toString();
    }

    private static boolean appendQuery(StringBuilder path, String key, String value, boolean hasQuery) {
        if (value == null || value.isBlank()) {
            return hasQuery;
        }
        path.append(hasQuery ? "&" : "?");
        path.append(key).append("=").append(value);
        return true;
    }
}
