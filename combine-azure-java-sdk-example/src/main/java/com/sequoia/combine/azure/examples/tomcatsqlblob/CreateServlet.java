package com.sequoia.combine.azure.examples.tomcatsqlblob;

import java.io.IOException;
import java.time.LocalDate;
import org.apache.logging.log4j.LogManager;
import org.apache.logging.log4j.Logger;

import com.sequoia.combine.azure.examples.tomcatsqlblob.models.Task;

import jakarta.persistence.EntityManager;
import jakarta.persistence.EntityManagerFactory;
import jakarta.persistence.EntityTransaction;
import jakarta.servlet.*;
import jakarta.servlet.annotation.WebServlet;
import jakarta.servlet.http.*;

@WebServlet(urlPatterns = "/create")
public class CreateServlet extends HttpServlet  {

    private static Logger logger = LogManager.getLogger(CreateServlet.class.getName());

    @Override
    protected void doPost(HttpServletRequest req, HttpServletResponse resp) throws ServletException, IOException {
        logger.info("POST /create");

        String name = req.getParameter("name");
        String dateStr = req.getParameter("date");

        if (name == null || dateStr == null)
            throw new ServletException("Error: parameters missing.");

        LocalDate dueDate = LocalDate.parse(dateStr);

        EntityManagerFactory emf = (EntityManagerFactory) req.getServletContext().getAttribute("EMFactory");
        EntityManager em = emf.createEntityManager();
        EntityTransaction transaction = em.getTransaction();
        try {
            transaction.begin();
            Task task = new Task();
            task.setName(name);
            task.setDueDate(dueDate);
            em.persist(task);
            transaction.commit();
        } catch (Exception e) {
            if(transaction != null && transaction.isActive())
                transaction.rollback();
            throw e;
        } finally {
            em.close();
        }

        String redirect = RedirectHelper.buildRedirectPath(req);
        resp.sendRedirect(redirect);
    }
}
