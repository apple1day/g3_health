import { parseSnapshot, type Snapshot } from './model';
export function demoSnapshot(now = new Date()): Snapshot {
  const sleepEnd = new Date(now); sleepEnd.setHours(7, 10, 0, 0);
  if (sleepEnd > now) sleepEnd.setDate(sleepEnd.getDate()-1);
  const sleepStart = new Date(sleepEnd.getTime()-8*3600_000);
  const workoutStart = new Date(sleepEnd); workoutStart.setDate(workoutStart.getDate()-1); workoutStart.setHours(18,0,0,0);
  const zone = Intl.DateTimeFormat().resolvedOptions().timeZone;
  const parts = new Intl.DateTimeFormat('en-CA',{ timeZone:zone,year:'numeric',month:'2-digit',day:'2-digit' }).formatToParts(now);
  const get=(type:string)=>parts.find(part=>part.type===type)!.value;
  return parseSnapshot({schemaVersion:1,dataMode:'demo',generatedAt:now.toISOString(),day:`${get('year')}-${get('month')}-${get('day')}`,timeZone:zone,sourcePolicy:'healthKit',
    sleep:{status:'ok',startedAt:sleepStart.toISOString(),endedAt:sleepEnd.toISOString(),totalMinutes:430,coreMinutes:245,deepMinutes:70,remMinutes:100,unspecifiedMinutes:15,awakeMinutes:30,sourceName:'演示 Apple Watch'},
    activity:{status:'ok',steps:6820,distanceMeters:4810,activeEnergyKcal:328,exerciseMinutes:24,standHours:7,activeEnergyGoalKcal:500,exerciseGoalMinutes:30,standGoalHours:12,moveMode:'energy'},
    heartRate:{status:'ok',bpm:72,measuredAt:new Date(now.getTime()-8*60_000).toISOString()},
    workout:{status:'ok',kind:'户外跑步',startedAt:workoutStart.toISOString(),endedAt:new Date(workoutStart.getTime()+1920_000).toISOString(),durationSeconds:1920,distanceMeters:5020,activeEnergyKcal:320},
    warnings:['演示数据，不代表你的健康记录。']});
}
