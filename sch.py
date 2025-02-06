from fastapi import FastAPI
from apscheduler.schedulers.asyncio import AsyncIOScheduler
from apscheduler.triggers.interval import IntervalTrigger
import asyncio
from oracle import scan_listening_ports, run_lsnrctl_status, consolidated_results

app = FastAPI()

# List of async function references
functions = [scan_listening_ports, run_lsnrctl_status, consolidated_results]

# Scheduler setup
scheduler = AsyncIOScheduler()


async def scheduled_job():
    results = []
    for func in functions:
        if asyncio.iscoroutinefunction(func):
            if func.__name__ == "run_lsnrctl_status":
                # Provide an argument for async functions that require it
                result = await func("LISTENER_1")
            else:
                result = await func()
        else:
            result = func()  # For non-async functions
        results.append({func.__name__: result})

    # Print or log the results (replace with your own logic if needed)
    print(results)


# Schedule the job to run every 10 seconds
scheduler.add_job(scheduled_job, IntervalTrigger(seconds=10))
scheduler.start()


@app.get("/")
async def root():
    return {"message": "FastAPI app with async scheduled job running every 10 seconds"}


# Graceful shutdown for the scheduler
@app.on_event("shutdown")
def shutdown_event():
    scheduler.shutdown()
