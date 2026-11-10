# My PEAQ roadmap

My PEAQ already shows sleep history, activity goals, workouts, PAI, and health trends from the PEAQ PSR 100. The next features will help people see what changed, compare it with their usual patterns, and record what was different that day.

## Implemented in 0.3.0

### 1. Sleep timing and regularity

- Add a **Duration / Timing** toggle to the 7-day and 30-day sleep charts.
- Show each night's recorded sleep start and end on a shared overnight clock, using the clock times recorded by the ring.
- Leave gaps for missing nights and let users tap a recorded night to open the existing sleep details screen.

### 2. Weekly review

- Summarize average sleep duration, days that met each activity goal, workout count, average recorded heart rate, and HRV.
- Compare with the previous week and show how many days or nights contributed to each summary.

## Later releases

### 3. Personal recovery insights

- Extend the existing HRV baseline approach to resting heart rate and respiratory rate when enough data is available.
- Explain deviations from a user's usual range and let users see the underlying readings.
- Consider a readiness score after the individual indicators are useful and easy to interpret.

### 4. Tags and a private journal

- Let users attach local notes and quick tags such as **Travel**, **Late meal**, or **Hard workout** to a day or night.
- Show tags on trend charts so users can compare tagged days with their usual patterns.

### 5. Apple Health integration

- Start with opt-in export for verified readings such as heart rate. Request permission for each supported data type.
- Use stable HealthKit sync identifiers so repeat syncs can update existing samples.
- Add sleep export once the app can reliably resolve the recording's time zone. The ring's reported clock times alone cannot establish the absolute timestamps required for export.

### 6. Data portability and daily convenience

- Add a local CSV export for reviewing readings outside the app.
- Add a separate backup-and-restore flow for moving or recovering app history.
- Add a Home Screen widget for steps toward goal, last night's sleep, or the latest ring sync.

## Additional priorities

### 7. Sync history and data freshness

- Show when each metric last received a reading and summarize what the latest sync imported.
- Distinguish a sync still in progress from a completed sync with no new readings. Show gaps in recorded data.

### 8. Sleep corrections and nap management

- Let users mark a session as a nap, adjust its boundaries, or exclude it from summaries.
- Keep the original ring readings so users can undo corrections.

### 9. Battery planning

- Show the ring's battery trend since its last charge and offer an optional low-battery reminder.
- Estimate whether the ring is likely to last overnight once enough battery history is available.

## Further ideas

### 10. Workout details

- Give each workout a detail screen with duration, distance, pace, and heart-rate zones where the ring provides enough data.
- Let users rename and categorize workouts.

### 11. Live spot checks

- Explore on-demand heart-rate and blood oxygen readings, subject to PSR 100 support.
- Save successful spot checks as clearly labeled manual readings.

### 12. Customizable Today screen

- Let users pin, reorder, or hide dashboard cards to match what they use most.

### 13. Activity by time of day

- Show hourly steps and active periods so users can see when they moved during the day.

### 14. Compare two periods

- Compare periods such as this month and last month, weekdays and weekends, or a trip and the weeks around it.
- Show data coverage for both periods.

### 15. Ring replacement and history

- Guide users through switching to a replacement ring.
- Keep earlier readings browsable and label which ring recorded them.
