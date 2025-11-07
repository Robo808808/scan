from fastapi import FastAPI
from apscheduler.schedulers.asyncio import AsyncIOScheduler
from apscheduler.triggers.interval import IntervalTrigger
import asyncio
from oracle import scan_listening_ports, run_lsnrctl_status, consolidated_results
from sqlite_helpers import init_db, insert_result  # Import the helper functions

app = FastAPI()

# Initialize the SQLite database
init_db()

# List of async function references
functions = [scan_listening_ports, run_lsnrctl_status, consolidated_results]

# Scheduler setup
scheduler = AsyncIOScheduler()

async def scheduled_job():
    results = []  # List to hold the function results
    for func in functions:
        if asyncio.iscoroutinefunction(func):
            # Handle async functions that require arguments
            if func.__name__ == "run_lsnrctl_status":
                # Provide the necessary argument for this function
                result = await func("LISTENER_1")
            else:
                result = await func()  # Call async functions without args
        else:
            result = func()  # For non-async functions (if any)

        # Insert the function name and its result into the SQLite database
        insert_result(func.__name__, result)

        results.append({func.__name__: result})  # Collect the results in the list

    # Log or print the results (optional)
    print("Scheduled job results:", results)

scheduler.add_job(scheduled_job, IntervalTrigger(seconds=10))
scheduler.start()

@app.get("/")
async def root():
    return {"message": "FastAPI app with async scheduled job running every 10 seconds"}

@app.on_event("shutdown")
def shutdown_event():
    scheduler.shutdown()

