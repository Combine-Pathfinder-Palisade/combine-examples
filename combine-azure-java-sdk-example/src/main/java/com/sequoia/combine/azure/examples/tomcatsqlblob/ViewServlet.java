package com.sequoia.combine.azure.examples.tomcatsqlblob;

import java.io.IOException;
import java.time.LocalDate;
import java.time.YearMonth;
import java.time.format.TextStyle;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Locale;

import org.apache.logging.log4j.LogManager;
import org.apache.logging.log4j.Logger;

import com.sequoia.combine.azure.examples.tomcatsqlblob.models.Task;
import com.sequoia.combine.azure.examples.tomcatsqlblob.storage.BackgroundImageStorageService;

import jakarta.persistence.EntityManager;
import jakarta.persistence.EntityManagerFactory;
import jakarta.persistence.EntityTransaction;
import jakarta.servlet.ServletException;
import jakarta.servlet.annotation.WebServlet;
import jakarta.servlet.http.HttpServlet;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;

@WebServlet(urlPatterns = "/")
public class ViewServlet extends HttpServlet {
    private static Logger logger = LogManager.getLogger(ViewServlet.class.getName());
    private transient BackgroundImageStorageService backgroundImageStorageService;

    @Override
    protected void doGet(HttpServletRequest req, HttpServletResponse resp) throws ServletException, IOException {

        logger.info("GET /");

        YearMonth targetMonth = resolveMonth(req);
        LocalDate firstDay = targetMonth.atDay(1);
        LocalDate lastDay = targetMonth.atEndOfMonth();
        int startOffset = firstDay.getDayOfWeek().getValue() % 7;

        LocalDate selectedDate = resolveSelectedDate(req, targetMonth);
        String selectedDateStr = selectedDate.toString();

        Map<String, List<Task>> tasksByDate = new HashMap<String, List<Task>>();

        EntityManagerFactory emf = (EntityManagerFactory) req.getServletContext().getAttribute("EMFactory");
        EntityManager em = emf.createEntityManager();
        EntityTransaction transaction = em.getTransaction();
        try {
            transaction.begin();
            List<Task> tasks = em.createQuery(
                    "SELECT t FROM Task t WHERE t.dueDate BETWEEN :start AND :end ORDER BY t.dueDate, t.id",
                    Task.class)
                .setParameter("start", firstDay)
                .setParameter("end", lastDay)
                .getResultList();
            transaction.commit();

            for (Task task : tasks) {
                String dateKey = task.getDueDate().toString();
                tasksByDate.computeIfAbsent(dateKey, k -> new ArrayList<Task>()).add(task);
            }
        } catch (Exception e) {
            logger.info("exception thrown: " + e.getMessage());
            if(transaction != null && transaction.isActive()) {
                transaction.rollback();
            }
            throw e;
        } finally {
            em.close();
        }

        YearMonth prevMonth = targetMonth.minusMonths(1);
        YearMonth nextMonth = targetMonth.plusMonths(1);

        req.setAttribute("year", targetMonth.getYear());
        req.setAttribute("month", targetMonth.getMonthValue());
        req.setAttribute("monthName", targetMonth.getMonth().getDisplayName(TextStyle.FULL, Locale.ENGLISH));
        req.setAttribute("daysInMonth", targetMonth.lengthOfMonth());
        req.setAttribute("startOffset", startOffset);
        req.setAttribute("tasksByDate", tasksByDate);
        req.setAttribute("selectedDate", selectedDateStr);
        req.setAttribute("selectedTasks", tasksByDate.getOrDefault(selectedDateStr, new ArrayList<Task>()));
        req.setAttribute("prevYear", prevMonth.getYear());
        req.setAttribute("prevMonth", prevMonth.getMonthValue());
        req.setAttribute("nextYear", nextMonth.getYear());
        req.setAttribute("nextMonth", nextMonth.getMonthValue());
        req.setAttribute("today", LocalDate.now().toString());
        req.setAttribute("dayList", buildDayList(targetMonth));

        try {
            BackgroundImageStorageService svc = getBackgroundImageStorageService();
            String backgroundUrl = svc.getBackgroundUrl();
            req.setAttribute("backgroundUrl", backgroundUrl);
        } catch (RuntimeException ex) {
            logger.warn("Unable to resolve background: {}", ex.getMessage());
        }

        req.getRequestDispatcher("/WEB-INF/views/tasksPage.jsp").forward(req, resp);
    }

    private List<LocalDate> buildDayList(YearMonth targetMonth) {
        List<LocalDate> days = new ArrayList<LocalDate>();
        for (int d = 1; d <= targetMonth.lengthOfMonth(); d++) {
            days.add(targetMonth.atDay(d));
        }
        return days;
    }

    private YearMonth resolveMonth(HttpServletRequest req) {
        String yearParam = req.getParameter("year");
        String monthParam = req.getParameter("month");

        LocalDate now = LocalDate.now();
        int year = now.getYear();
        int month = now.getMonthValue();

        try {
            if (yearParam != null) {
                year = Integer.parseInt(yearParam);
            }
            if (monthParam != null) {
                month = Integer.parseInt(monthParam);
            }
        } catch (NumberFormatException e) {
            logger.info("Invalid month/year provided, defaulting to current month.");
        }

        if (month < 1 || month > 12) {
            month = now.getMonthValue();
        }

        return YearMonth.of(year, month);
    }

    private BackgroundImageStorageService getBackgroundImageStorageService() {
        if (backgroundImageStorageService == null) {
            backgroundImageStorageService = new BackgroundImageStorageService();
        }
        return backgroundImageStorageService;
    }

    private LocalDate resolveSelectedDate(HttpServletRequest req, YearMonth targetMonth) {
        String selected = req.getParameter("selected");
        if (selected != null && !selected.isBlank()) {
            try {
                LocalDate parsed = LocalDate.parse(selected);
                if (parsed.getYear() == targetMonth.getYear() && parsed.getMonthValue() == targetMonth.getMonthValue()) {
                    return parsed;
                }
            } catch (Exception e) {
                logger.info("Invalid selected date provided, ignoring.");
            }
        }

        LocalDate today = LocalDate.now();
        if (today.getYear() == targetMonth.getYear() && today.getMonthValue() == targetMonth.getMonthValue()) {
            return today;
        }

        return targetMonth.atDay(1);
    }
}
