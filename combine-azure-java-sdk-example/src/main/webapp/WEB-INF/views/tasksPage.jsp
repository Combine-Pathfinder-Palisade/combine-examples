<!DOCTYPE html>
<%@ taglib prefix="c" uri="http://java.sun.com/jsp/jstl/core" %>
<%@ taglib prefix="fn" uri="http://java.sun.com/jsp/jstl/functions" %>
<html>
<head>
    <meta charset="UTF-8">
    <title>Calendar Tasks</title>
    <base href="${pageContext.request.contextPath}/"/>
    <link rel="stylesheet" href="bootstrap-5.3.8-dist/css/bootstrap.min.css" crossorigin="anonymous">
    <style>
        body { background: #f7f8fa; }
        .calendar-grid { display: grid; grid-template-columns: repeat(7, 1fr); gap: 8px; }
        .weekday { text-align: center; font-weight: 600; color: #6c757d; }
        .day-card { background: #fff; border-radius: 8px; padding: 10px; min-height: 110px; box-shadow: 0 1px 2px rgba(0,0,0,0.05); border: 1px solid #e9ecef; }
        .day-card.today { border-color: #0d6efd; box-shadow: 0 0 0 2px rgba(13,110,253,.15); }
        .day-card.selected { border-color: #6610f2; box-shadow: 0 0 0 2px rgba(102,16,242,.18); }
        .day-number { font-weight: 700; }
        .task-pill { background: #e9f3ff; color: #0d6efd; border-radius: 12px; padding: 2px 8px; display: inline-block; font-size: 12px; margin-top: 4px; }
        .empty-slot { visibility: hidden; }
        .calendar-actions button { min-width: 46px; }
        .task-actions form { display: inline-block; margin-right: 6px; }
        .muted { color: #6c757d; }
        .day-button { padding: 0; border: 0; background: transparent; width: 100%; text-align: left; }
        .day-button:focus-visible { outline: 2px solid #0d6efd; outline-offset: 2px; }
        .calendar-wrapper { background: #fff; border: 1px solid #e9ecef; border-radius: 8px; padding: 16px; box-shadow: 0 1px 2px rgba(0,0,0,0.05); }
        .side-panel { position: sticky; top: 16px; min-width: 520px; }
        .card h6 { font-weight: 600; }
        .muted-small { font-size: 13px; color: #6c757d; }
        .day-count { min-width: 22px; height: 22px; border-radius: 11px; background: #0d6efd; color: #fff; font-size: 12px; font-weight: 600; display: inline-flex; align-items: center; justify-content: center; padding: 0 6px; }
        .task-list { max-height: 52px; overflow: hidden; display: grid; gap: 4px; }
        .task-list .task-pill { justify-self: start; width: fit-content; max-width: 100%; }
        .page-shell { padding-left: 24px; padding-right: 24px; }
        .equal-gap { --bs-gutter-x: 24px; }
        .task-row { display: grid; grid-template-columns: minmax(200px, 2fr) minmax(150px, 1.2fr) auto auto; gap: 10px; align-items: center; }
        .task-row .form-control { width: 100%; }
        .action-buttons { display: flex; gap: 8px; justify-content: flex-end; flex-wrap: wrap; }
        .action-buttons .btn { width: auto; white-space: nowrap; padding-left: 14px; padding-right: 14px; }
        @media (max-width: 768px) { .task-row { grid-template-columns: 1fr 1fr; } }
        @media (max-width: 576px) { .task-row { grid-template-columns: 1fr; } }
        summary { list-style: none; }
        summary::-webkit-details-marker { display: none; }
        .collapse-toggle { cursor: pointer; }
        .collapse-arrow {
            display: inline-block;
            width: 0;
            height: 0;
            border-top: 6px solid transparent;
            border-bottom: 6px solid transparent;
            border-left: 7px solid #6c757d;
            transition: transform 0.15s ease;
        }
        details[open] .collapse-arrow { transform: rotate(90deg); }
    </style>
    <c:if test="${not empty backgroundUrl}">
        <style>
            body { background: url('${fn:escapeXml(backgroundUrl)}') center/cover no-repeat fixed; }
        </style>
    </c:if>
</head>
<body>
<div class="container-fluid py-4 page-shell">
    <div class="row equal-gap align-items-start">
        <div class="col-xl-8 col-lg-7">
            <div class="calendar-wrapper">
                <div class="d-flex justify-content-between align-items-center mb-3">
                    <form method="get" class="calendar-actions mb-0">
                        <input type="hidden" name="year" value="${prevYear}" />
                        <input type="hidden" name="month" value="${prevMonth}" />
                        <input type="hidden" name="selected" value="${selectedDate}" />
                        <button class="btn btn-outline-secondary" type="submit">&#8592; Prev</button>
                    </form>

                    <div class="text-center">
                        <h3 class="mb-0">${monthName} ${year}</h3>
                        <div class="muted-small">Click a date to focus tasks</div>
                    </div>

                    <form method="get" class="calendar-actions mb-0">
                        <input type="hidden" name="year" value="${nextYear}" />
                        <input type="hidden" name="month" value="${nextMonth}" />
                        <input type="hidden" name="selected" value="${selectedDate}" />
                        <button class="btn btn-outline-secondary" type="submit">Next &#8594;</button>
                    </form>
                </div>

                <div class="calendar-grid mb-2">
                    <div class="weekday">Sun</div>
                    <div class="weekday">Mon</div>
                    <div class="weekday">Tue</div>
                    <div class="weekday">Wed</div>
                    <div class="weekday">Thu</div>
                    <div class="weekday">Fri</div>
                    <div class="weekday">Sat</div>
                </div>

                <div class="calendar-grid">
                    <c:if test="${startOffset > 0}">
                        <c:forEach begin="1" end="${startOffset}" var="i">
                            <div class="day-card empty-slot"></div>
                        </c:forEach>
                    </c:if>

                    <c:forEach items="${dayList}" var="day">
                        <c:set var="dateStr" value="${day.toString()}" />
                        <c:set var="isToday" value="${dateStr == today}" />
                        <c:set var="isSelected" value="${dateStr == selectedDate}" />
                        <c:set var="taskCount" value="${fn:length(tasksByDate[dateStr])}" />
                        <form method="get" class="mb-0">
                            <input type="hidden" name="year" value="${year}" />
                            <input type="hidden" name="month" value="${month}" />
                            <input type="hidden" name="selected" value="${dateStr}" />
                            <button type="submit" class="day-button">
                                <div class="day-card ${isToday ? 'today' : ''} ${isSelected ? 'selected' : ''}">
                                    <div class="d-flex justify-content-between align-items-center mb-1">
                                        <span class="day-number">${day.dayOfMonth}</span>
                                        <c:if test="${taskCount > 0}">
                                            <span class="day-count">${taskCount}</span>
                                        </c:if>
                                    </div>
                                    <c:if test="${taskCount > 0}">
                                        <div class="task-list">
                                            <c:forEach items="${tasksByDate[dateStr]}" var="task" begin="0" end="${taskCount > 2 ? 1 : taskCount - 1}">
                                                <div class="task-pill text-truncate" title="${task.name}">${task.name}</div>
                                            </c:forEach>
                                            <c:if test="${taskCount > 2}">
                                                <div class="muted" style="font-size: 12px;">More tasks...</div>
                                            </c:if>
                                        </div>
                                    </c:if>
                                </div>
                            </button>
                        </form>
                    </c:forEach>
                </div>
            </div>
        </div>

        <div class="col-xl-4 col-lg-5">
            <div class="card shadow-sm side-panel">
                <div class="card-header d-flex justify-content-between align-items-center">
                    <div>
                        <div class="muted">Selected date</div>
                        <h5 class="mb-0">${selectedDate}</h5>
                    </div>
                    <div class="text-end">
                        <div class="muted-small">Jump to another month</div>
                        <form method="get" class="d-flex gap-2 mb-0">
                            <input type="number" class="form-control" name="month" min="1" max="12" value="${month}" style="width: 90px;" />
                            <input type="number" class="form-control" name="year" min="1900" max="3000" value="${year}" style="width: 110px;" />
                            <input type="hidden" name="selected" value="${selectedDate}" />
                            <button class="btn btn-outline-primary" type="submit">Go</button>
                        </form>
                    </div>
                </div>
                <div class="card-body">
                    <h6>Add task</h6>
                    <form action="create" method="post" class="row g-2 mb-3">
                        <div class="col-md-8">
                            <input type="text" name="name" class="form-control" placeholder="Task description" required />
                        </div>
                        <div class="col-md-4">
                            <input type="date" name="date" class="form-control" value="${selectedDate}" required />
                        </div>
                        <input type="hidden" name="year" value="${year}" />
                        <input type="hidden" name="month" value="${month}" />
                        <input type="hidden" name="selected" value="${selectedDate}" />
                        <div class="col-12">
                            <button type="submit" class="btn btn-primary w-100">Add</button>
                        </div>
                    </form>

                    <c:if test="${empty selectedTasks}">
                        <div class="muted">No tasks yet.</div>
                    </c:if>

                    <c:forEach items="${selectedTasks}" var="task">
                        <div class="border rounded p-2 mb-2">
                            <form action="update" method="post" class="task-row">
                                <input type="hidden" name="id" value="${task.id}" />
                                <input type="text" name="name" class="form-control" value="${task.name}" required />
                                <input type="date" name="date" class="form-control" value="${task.dueDate}" required />
                                <input type="hidden" name="year" value="${year}" />
                                <input type="hidden" name="month" value="${month}" />
                                <input type="hidden" name="selected" value="${selectedDate}" />
                                <div class="action-buttons">
                                    <button type="submit" class="btn btn-success">Save</button>
                                    <button type="submit" form="delete-${task.id}" class="btn btn-outline-danger">Delete</button>
                                </div>
                            </form>
                            <form id="delete-${task.id}" action="delete" method="post" class="d-none">
                                <input type="hidden" name="id" value="${task.id}" />
                                <input type="hidden" name="year" value="${year}" />
                                <input type="hidden" name="month" value="${month}" />
                                <input type="hidden" name="selected" value="${selectedDate}" />
                            </form>
                        </div>
                    </c:forEach>
                </div>
            </div>

            <details class="card shadow-sm mt-3" open>
                <summary class="card-header d-flex justify-content-between align-items-center collapse-toggle">
                    <h6 class="mb-0">Background image</h6>
                    <span class="collapse-arrow" aria-hidden="true"></span>
                </summary>
                <div class="card-body">
                    <form action="upload-background" method="post" enctype="multipart/form-data" class="row g-2 mb-3">
                        <div class="col-12">
                            <label class="form-label mb-1">PNG or JPG (max 5 MB)</label>
                            <input type="file" name="backgroundImage" class="form-control" accept="image/png,image/jpeg" required />
                        </div>
                        <input type="hidden" name="year" value="${year}" />
                        <input type="hidden" name="month" value="${month}" />
                        <input type="hidden" name="selected" value="${selectedDate}" />
                        <div class="col-12">
                            <button type="submit" class="btn btn-outline-primary w-100">Upload background</button>
                        </div>
                    </form>
                    <form action="delete-background" method="post" class="mb-2">
                        <input type="hidden" name="year" value="${year}" />
                        <input type="hidden" name="month" value="${month}" />
                        <input type="hidden" name="selected" value="${selectedDate}" />
                        <button type="submit" class="btn btn-outline-danger w-100">Remove background</button>
                    </form>
                    <p class="muted mb-0" style="font-size: 13px;">Uploads replace the background. Removing clears the background.</p>
                </div>
            </details>
        </div>
    </div>
</div>
<!-- <script src="../../bootstrap-5.3.8-dist/js/bootstrap.min.js"></script> -->
</body>
</html>
