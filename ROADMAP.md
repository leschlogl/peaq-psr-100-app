# My PEAQ roadmap

My PEAQ shows sleep history, activity goals, step history, PAI, and health trends from the PEAQ PSR 100. The next features will help people see what changed, compare it with their usual patterns, and record what was different that day.

## Implemented in 0.6.0

### Step history

- Tap the steps ring on **Today** to browse hourly step changes or see the last recorded daily totals over 7 or 30 days against your step goal.
- Use the calendar to find days with saved step readings. Slide across the chart to inspect values. Hourly labels use local time, and gaps stay visible when the readings cannot establish an hourly count.

### Exercise records

- Removed the **Exercise records** card from Insights while we verify how the original app records and syncs workouts. My PEAQ still stores workout records received from the ring.

## Implemented in 0.5.0

### Personal baselines

- Compare daily HRV and respiratory rate with a personal range built from the prior 28 days.
- Show coverage, missing readings, and a seven-day chart. Build the range after at least seven recorded days.

### Sleep corrections and naps

- Use the pencil on a sleep detail screen to mark a session as a nap, exclude it from summaries, or restore it.
- Keep the original recordings accessible and apply corrections to sleep trends and Weekly Review.

### Low-battery reminders

- Opt in under **My Ring → Battery** and choose a reminder threshold.
- Check fresh readings and send one reminder per low-battery period, with settings saved per ring.

## Implemented in 0.4.0

### 7. Sync history and data freshness

- Show the latest sync outcome and saved counts in **My Ring**, alongside the last successful sync.
- Keep up to 30 recent attempts per ring and distinguish completed syncs with no changes from failures and interruptions.
- Show separate freshness dates for saved sleep, activity, and heart readings.

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

- Extend personal baselines to resting heart rate once resting samples can be identified reliably.
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

### 8. Sleep corrections and nap management

- Extend the existing reversible corrections with start and end time adjustments.
- Preserve original readings and keep corrections consistent across charts and summaries.

### 9. Battery planning

- Add a battery trend since the last charge alongside the existing low-battery reminders.
- Estimate whether the ring is likely to last overnight once enough battery history is available.

## Further ideas

### 10. Workout recording and details

- Verify how the original app handles workout sessions and which readings the ring can provide live.
- If workouts need to be recorded in My PEAQ, explore a Start/Stop flow that saves session readings locally.
- Give each workout a detail screen with duration, distance, pace, and heart-rate zones where the ring provides enough data.
- Let users rename and categorize workouts.

### 11. Live spot checks

- Explore on-demand heart-rate and blood oxygen readings, subject to PSR 100 support.
- Save successful spot checks as clearly labeled manual readings.

### 12. Customizable Today screen

- Let users pin, reorder, or hide dashboard cards to match what they use most.

### 14. Compare two periods

- Compare periods such as this month and last month, weekdays and weekends, or a trip and the weeks around it.
- Show data coverage for both periods.

### 15. Ring replacement and history

- Guide users through switching to a replacement ring.
- Keep earlier readings browsable and label which ring recorded them.
