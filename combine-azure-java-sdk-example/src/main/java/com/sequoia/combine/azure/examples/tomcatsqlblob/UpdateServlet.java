package com.sequoia.combine.azure.examples.tomcatsqlblob;

import java.io.IOException;
import java.time.LocalDate;

import org.apache.logging.log4j.LogManager;
import org.apache.logging.log4j.Logger;

import com.sequoia.combine.azure.examples.tomcatsqlblob.models.Task;

import jakarta.persistence.EntityManager;
import jakarta.persistence.EntityManagerFactory;
import jakarta.persistence.EntityTransaction;
import jakarta.servlet.ServletException;
import jakarta.servlet.annotation.WebServlet;
import jakarta.servlet.http.HttpServlet;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;

@WebServlet(urlPatterns = "/update")
public class UpdateServlet extends HttpServlet {

    private static Logger logger = LogManager.getLogger(UpdateServlet.class.getName());

    @Override
    protected void doPost(HttpServletRequest req, HttpServletResponse resp) throws ServletException, IOException {
        logger.info("POST /update");

        String idStr = req.getParameter("id");
        String name = req.getParameter("name");
        String dateStr = req.getParameter("date");

        if (idStr == null || name == null || dateStr == null) {
            throw new ServletException("Error: parameters missing.");
        }

        Long id = Long.parseLong(idStr);
        LocalDate dueDate = LocalDate.parse(dateStr);

        EntityManagerFactory emf = (EntityManagerFactory) req.getServletContext().getAttribute("EMFactory");
        EntityManager em = emf.createEntityManager();
        EntityTransaction transaction = em.getTransaction();
        try {
            transaction.begin();
            Task task = em.find(Task.class, id);
            if (task != null) {
                task.setName(name);
                task.setDueDate(dueDate);
            }
            transaction.commit();
        } catch (Exception e) {
            if (transaction != null && transaction.isActive()) {
                transaction.rollback();
            }
            throw e;
        } finally {
            em.close();
        }

        String redirect = RedirectHelper.buildRedirectPath(req);
        resp.sendRedirect(redirect);
    }
}
