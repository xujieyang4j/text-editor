import {
  Bell,
  BookOpenText,
  ChartNoAxesCombined,
  ChevronDown,
  CircleCheckBig,
  Clock3,
  Crosshair,
  FlaskConical,
  List,
  ListFilter,
  MapPin,
  Maximize2,
  Minus,
  MousePointer2,
  MousePointerClick,
  Move,
  PanelLeftClose,
  Pause,
  Play,
  Plus,
  Radar,
  RadioTower,
  Search,
  Server,
  ShieldAlert,
  SkipBack,
  SkipForward,
  TriangleAlert,
  Users,
  Workflow,
  createIcons
} from 'lucide'
import './incidentDashboard.css'

type Severity = 'P1' | 'P2' | 'P3'
type IncidentStatus = 'active' | 'investigating' | 'monitoring'
type LogKind = 'alert' | 'status' | 'system'

interface Incident {
  id: string
  city: string
  country: string
  region: string
  regionCode: string
  severity: Severity
  status: IncidentStatus
  x: number
  y: number
  source: string
  protocol: string
  confidence: number
  title: string
  duration: string
  users: string
  impact: string
  owner: string
  initials: string
  timelineIndex: number
  service: string
}

interface TimelineEvent {
  time: string
  title: string
  detail: string
  kind: LogKind
  severity?: Severity
  incidentId?: string
}

const incidents: Incident[] = [
  { id: 'INC-0422-A', city: 'Frankfurt', country: 'Germany', region: 'Europe', regionCode: 'eu-central-1', severity: 'P1', status: 'active', x: 52.7, y: 39.4, source: 'edge-fw-07', protocol: 'TLS / 443', confidence: 97, title: 'Database latency in EU Central', duration: '00:47:28', users: '184.2K', impact: 'High', owner: 'Maya Chen', initials: 'MC', timelineIndex: 3, service: 'Database' },
  { id: 'INC-0419-B', city: 'Ashburn', country: 'United States', region: 'North America', regionCode: 'us-east-1', severity: 'P1', status: 'investigating', x: 24.8, y: 37.5, source: 'auth-proxy-12', protocol: 'HTTPS / 443', confidence: 94, title: 'Authentication error-rate spike', duration: '00:31:12', users: '91.6K', impact: 'High', owner: 'Noah Wright', initials: 'NW', timelineIndex: 2, service: 'Authentication' },
  { id: 'INC-0431-C', city: 'Singapore', country: 'Singapore', region: 'Asia Pacific', regionCode: 'ap-southeast-1', severity: 'P2', status: 'active', x: 78.5, y: 59.3, source: 'cdn-edge-19', protocol: 'HTTP/2', confidence: 89, title: 'Elevated edge timeout rate', duration: '00:24:03', users: '42.8K', impact: 'Medium', owner: 'Ari Patel', initials: 'AP', timelineIndex: 4, service: 'CDN' },
  { id: 'INC-0417-D', city: 'São Paulo', country: 'Brazil', region: 'South America', regionCode: 'sa-east-1', severity: 'P2', status: 'monitoring', x: 35.1, y: 72.1, source: 'api-gw-03', protocol: 'gRPC', confidence: 83, title: 'API saturation recovered', duration: '01:14:55', users: '18.4K', impact: 'Medium', owner: 'Luis Costa', initials: 'LC', timelineIndex: 1, service: 'API Gateway' },
  { id: 'INC-0428-E', city: 'Tokyo', country: 'Japan', region: 'Asia Pacific', regionCode: 'ap-northeast-1', severity: 'P2', status: 'investigating', x: 86.6, y: 38.2, source: 'payments-04', protocol: 'TCP / 5432', confidence: 91, title: 'Payment queue backlog', duration: '00:19:41', users: '23.1K', impact: 'Medium', owner: 'Emi Sato', initials: 'ES', timelineIndex: 5, service: 'Database' },
  { id: 'INC-0408-F', city: 'San Francisco', country: 'United States', region: 'North America', regionCode: 'us-west-1', severity: 'P3', status: 'monitoring', x: 15.2, y: 39.1, source: 'telemetry-08', protocol: 'UDP / 8125', confidence: 76, title: 'Telemetry ingestion delay', duration: '02:08:19', users: '4.9K', impact: 'Low', owner: 'Jules Kim', initials: 'JK', timelineIndex: 0, service: 'API Gateway' },
  { id: 'INC-0425-G', city: 'London', country: 'United Kingdom', region: 'Europe', regionCode: 'eu-west-2', severity: 'P3', status: 'active', x: 48.8, y: 33.5, source: 'cdn-edge-02', protocol: 'TLS / 443', confidence: 72, title: 'Cache miss ratio elevated', duration: '00:38:10', users: '12.7K', impact: 'Low', owner: 'Sam Reed', initials: 'SR', timelineIndex: 2, service: 'CDN' },
  { id: 'INC-0402-H', city: 'Sydney', country: 'Australia', region: 'Asia Pacific', regionCode: 'ap-southeast-2', severity: 'P3', status: 'monitoring', x: 88.1, y: 76.5, source: 'edge-fw-21', protocol: 'TLS / 443', confidence: 68, title: 'Intermittent connection churn', duration: '01:51:02', users: '6.2K', impact: 'Low', owner: 'Rae Wilson', initials: 'RW', timelineIndex: 6, service: 'Authentication' }
]

const timeline: TimelineEvent[] = [
  { time: '14:04:12', title: 'Anomaly detected', detail: 'Telemetry baseline exceeded in us-west-1.', kind: 'system', severity: 'P3', incidentId: 'INC-0408-F' },
  { time: '14:06:48', title: 'API saturation', detail: 'Latency crossed 850 ms in sa-east-1.', kind: 'alert', severity: 'P2', incidentId: 'INC-0417-D' },
  { time: '14:09:31', title: 'Auth errors correlated', detail: 'Three edge clusters reported token failures.', kind: 'alert', severity: 'P1', incidentId: 'INC-0419-B' },
  { time: '14:12:09', title: 'Incident escalated', detail: 'Database latency reached the critical threshold.', kind: 'status', severity: 'P1', incidentId: 'INC-0422-A' },
  { time: '14:14:55', title: 'Traffic shifted', detail: 'APAC traffic moved to healthy CDN capacity.', kind: 'status', severity: 'P2', incidentId: 'INC-0431-C' },
  { time: '14:17:24', title: 'Queue growth isolated', detail: 'Payment backlog isolated to ap-northeast-1.', kind: 'alert', severity: 'P2', incidentId: 'INC-0428-E' },
  { time: '14:20:02', title: 'Recovery checks started', detail: 'Global probes entered active verification.', kind: 'system', severity: 'P3', incidentId: 'INC-0402-H' }
]

const iconSet = {
  Bell, BookOpenText, ChartNoAxesCombined, ChevronDown, CircleCheckBig, Clock3,
  Crosshair, FlaskConical, List, ListFilter, MapPin, Maximize2, Minus,
  MousePointer2, MousePointerClick, Move, PanelLeftClose, Pause, Play, Plus,
  Radar, RadioTower, Search, Server, ShieldAlert, SkipBack, SkipForward,
  TriangleAlert, Users, Workflow
}

function selectElement<T extends Element>(selector: string): T {
  const element = document.querySelector<T>(selector)
  if (!element) throw new Error('Missing dashboard element: ' + selector)
  return element
}

function makeElement<K extends keyof HTMLElementTagNameMap>(tag: K, className?: string): HTMLElementTagNameMap[K] {
  const element = document.createElement(tag)
  if (className) element.className = className
  return element
}

function makeSeverityDot(severity: Severity): HTMLElement {
  const dot = makeElement('i', 'severity-dot ' + severity.toLowerCase())
  dot.setAttribute('aria-hidden', 'true')
  return dot
}

const mapViewport = selectElement<HTMLElement>('#map-viewport')
const mapStage = selectElement<HTMLElement>('#map-stage')
const markerHost = selectElement<HTMLElement>('#map-markers')
const locationList = selectElement<HTMLElement>('#location-list')
const mapEventList = selectElement<HTMLElement>('#map-event-list')
const mapEventListItems = selectElement<HTMLElement>('#map-event-list-items')
const visibleSignalCount = selectElement<HTMLElement>('#visible-signal-count')
const activityLog = selectElement<HTMLElement>('#activity-log')
const logCount = selectElement<HTMLElement>('#log-count')
const timelineEvents = selectElement<HTMLElement>('#timeline-events')
const timelineTrack = selectElement<HTMLElement>('#timeline-track')
const timelineProgress = selectElement<HTMLElement>('#timeline-progress')
const timeScrubber = selectElement<HTMLElement>('#time-scrubber')
const playbackToggle = selectElement<HTMLButtonElement>('#playback-toggle')
const playbackSpeed = selectElement<HTMLSelectElement>('#playback-speed')
const playbackClock = selectElement<HTMLElement>('#playback-clock')
const globalSearch = selectElement<HTMLInputElement>('#global-search')
const statusFilter = selectElement<HTMLSelectElement>('#status-filter')
const sidebar = selectElement<HTMLElement>('#sidebar')
const toast = selectElement<HTMLElement>('#toast')

let selectedIncidentId = 'INC-0422-A'
let selectedTimelineIndex = 3
let activeLogFilter: 'all' | LogKind = 'all'
let zoom = 1
let panX = 0
let panY = 0
let isSpacePressed = false
let dragOrigin: { x: number; y: number; panX: number; panY: number } | null = null
let playbackTimer: number | null = null
let simulationTimer: number | null = null
let toastTimer: number | null = null

function checkedValues(selector: string): Set<string> {
  return new Set([...document.querySelectorAll<HTMLInputElement>(selector + ' input:checked')].map(input => input.value))
}

function visibleIncidents(): Incident[] {
  const regions = checkedValues('#region-filters')
  const severities = checkedValues('#severity-filters')
  const state = statusFilter.value
  const query = globalSearch.value.trim().toLocaleLowerCase()
  return incidents.filter(incident => {
    const matchesText = !query || [incident.id, incident.city, incident.country, incident.title, incident.source, incident.service]
      .some(value => value.toLocaleLowerCase().includes(query))
    return regions.has(incident.region) && severities.has(incident.severity)
      && (state === 'all' || incident.status === state) && matchesText
  })
}

function renderMarkers(): void {
  const visible = visibleIncidents()
  markerHost.replaceChildren(...visible.map(incident => {
    const marker = makeElement('button', 'map-marker ' + incident.severity.toLowerCase())
    if (incident.id === selectedIncidentId) marker.classList.add('selected')
    marker.type = 'button'
    marker.style.left = incident.x + '%'
    marker.style.top = incident.y + '%'
    marker.dataset.incident = incident.id
    marker.setAttribute('aria-label', incident.severity + ' incident in ' + incident.city + ': ' + incident.title)
    const pulse = makeElement('span', 'pulse')
    const core = makeElement('span', 'marker-core')
    core.append(makeElement('span'), makeElement('span'), makeElement('span'))
    const label = makeElement('span', 'marker-label')
    label.textContent = incident.city
    marker.append(pulse, core, label)
    marker.addEventListener('click', () => selectIncident(incident.id, true))
    return marker
  }))
  visibleSignalCount.textContent = String(visible.length)
  mapEventListItems.replaceChildren(...visible.map(incident => {
    const item = makeElement('button')
    item.type = 'button'
    if (incident.id === selectedIncidentId) item.classList.add('selected')
    const line = makeElement('span')
    line.append(makeSeverityDot(incident.severity))
    const text = makeElement('span')
    const title = makeElement('strong')
    title.textContent = incident.city
    const detail = makeElement('small')
    detail.textContent = incident.title
    text.append(title, detail)
    const level = makeElement('b')
    level.textContent = incident.severity
    line.append(text)
    item.append(line, level)
    item.addEventListener('click', () => selectIncident(incident.id, true))
    return item
  }))
}

function renderLocations(): void {
  const visible = visibleIncidents()
  locationList.replaceChildren(...visible.map(incident => {
    const button = makeElement('button')
    button.type = 'button'
    if (incident.id === selectedIncidentId) button.classList.add('selected')
    const line = makeElement('span')
    line.append(makeSeverityDot(incident.severity), document.createTextNode(incident.city))
    const count = makeElement('b')
    count.textContent = incident.severity
    button.append(line, count)
    button.addEventListener('click', () => selectIncident(incident.id, true))
    return button
  }))
}

function renderTimeline(): void {
  timelineEvents.replaceChildren(...timeline.map((event, index) => {
    const button = makeElement('button', 'timeline-event ' + (event.severity?.toLowerCase() ?? 'neutral'))
    if (index === selectedTimelineIndex) button.classList.add('active')
    button.type = 'button'
    button.style.left = (index / Math.max(1, timeline.length - 1)) * 100 + '%'
    button.setAttribute('aria-label', event.time + ': ' + event.title)
    const dot = makeElement('span')
    const label = makeElement('small')
    label.textContent = event.time.slice(0, 5)
    button.append(dot, label)
    button.addEventListener('click', () => setTimelineIndex(index, true))
    return button
  }))
  const percent = (selectedTimelineIndex / Math.max(1, timeline.length - 1)) * 100
  timelineProgress.style.width = percent + '%'
  timeScrubber.style.left = percent + '%'
  timelineTrack.setAttribute('aria-valuemax', String(timeline.length - 1))
  timelineTrack.setAttribute('aria-valuenow', String(selectedTimelineIndex))
  playbackClock.textContent = timeline[selectedTimelineIndex].time + ' UTC'
}

function renderLogs(): void {
  const visible = timeline.slice(0, selectedTimelineIndex + 1)
    .filter(event => activeLogFilter === 'all' || event.kind === activeLogFilter)
    .reverse()
  activityLog.replaceChildren(...visible.map(event => {
    const row = makeElement('button', 'log-row')
    row.type = 'button'
    const time = makeElement('time')
    time.textContent = event.time
    const indicator = makeElement('i', 'log-indicator ' + (event.severity?.toLowerCase() ?? 'neutral'))
    const copy = makeElement('span')
    const title = makeElement('strong')
    title.textContent = event.title
    const detail = makeElement('small')
    detail.textContent = event.detail
    copy.append(title, detail)
    row.append(time, indicator, copy)
    row.addEventListener('click', () => {
      if (event.incidentId) selectIncident(event.incidentId, false)
    })
    return row
  }))
  logCount.textContent = visible.length + ' event' + (visible.length === 1 ? '' : 's')
}

function renderIncident(): void {
  const incident = incidents.find(candidate => candidate.id === selectedIncidentId) ?? incidents[0]
  selectElement('#signal-location').textContent = incident.city + ', ' + incident.country
  selectElement('#signal-source').textContent = incident.source
  selectElement('#signal-protocol').textContent = incident.protocol
  selectElement('#signal-confidence').textContent = incident.confidence + '%'
  const signalSeverity = selectElement('#signal-severity')
  signalSeverity.textContent = incident.severity
  signalSeverity.className = 'severity-badge ' + incident.severity.toLowerCase()
  selectElement('#incident-title').textContent = incident.title
  selectElement('#incident-region').textContent = incident.city + ' · ' + incident.regionCode
  selectElement('#incident-duration').textContent = incident.duration
  selectElement('#incident-users').textContent = incident.users
  selectElement('#incident-impact').textContent = incident.impact
  selectElement('#incident-owner').textContent = incident.owner
  selectElement('.owner b').textContent = incident.initials
  const badge = selectElement('#incident-badge')
  badge.textContent = incident.severity
  badge.className = 'severity-badge ' + incident.severity.toLowerCase()
  document.querySelectorAll<HTMLButtonElement>('[data-service]').forEach(button => {
    const impacted = button.dataset.service === incident.service
    button.classList.toggle('impacted', impacted)
    const small = button.querySelector('small')
    if (small) small.textContent = impacted ? (incident.severity === 'P1' ? 'Critical impact' : 'Degraded') : 'Operational'
  })
}

function selectIncident(id: string, syncTimeline: boolean): void {
  const incident = incidents.find(candidate => candidate.id === id)
  if (!incident) return
  selectedIncidentId = id
  if (syncTimeline) selectedTimelineIndex = incident.timelineIndex
  renderMarkers()
  renderLocations()
  renderTimeline()
  renderIncident()
  renderLogs()
}

function setTimelineIndex(index: number, selectLinkedIncident: boolean): void {
  selectedTimelineIndex = Math.max(0, Math.min(timeline.length - 1, index))
  const linked = timeline[selectedTimelineIndex].incidentId
  if (selectLinkedIncident && linked) selectedIncidentId = linked
  renderTimeline()
  renderLogs()
  renderIncident()
  renderMarkers()
  renderLocations()
}

function updateMapTransform(): void {
  mapStage.style.transform = 'translate(' + panX + 'px, ' + panY + 'px) scale(' + zoom + ')'
  selectElement('#zoom-value').textContent = Math.round(zoom * 100) + '%'
}

function setZoom(next: number, origin?: { x: number; y: number }): void {
  const clamped = Math.max(0.72, Math.min(2.4, next))
  if (origin && clamped !== zoom) {
    const rect = mapViewport.getBoundingClientRect()
    const pointX = origin.x - rect.left
    const pointY = origin.y - rect.top
    const ratio = clamped / zoom
    panX = pointX - (pointX - panX) * ratio
    panY = pointY - (pointY - panY) * ratio
  }
  zoom = clamped
  updateMapTransform()
}

function showToast(message: string): void {
  toast.textContent = message
  toast.classList.add('visible')
  if (toastTimer !== null) window.clearTimeout(toastTimer)
  toastTimer = window.setTimeout(() => toast.classList.remove('visible'), 2400)
}

function bindFilters(): void {
  document.querySelectorAll<HTMLInputElement>('#region-filters input, #severity-filters input').forEach(input => {
    input.addEventListener('change', () => {
      renderMarkers()
      renderLocations()
    })
  })
  statusFilter.addEventListener('change', () => {
    renderMarkers()
    renderLocations()
  })
  globalSearch.addEventListener('input', () => {
    renderMarkers()
    renderLocations()
  })
  globalSearch.addEventListener('keydown', event => {
    if (event.key !== 'Enter') return
    const first = visibleIncidents()[0]
    if (first) selectIncident(first.id, true)
    else showToast('No matching incidents')
  })
}

function bindMap(): void {
  selectElement('#zoom-in').addEventListener('click', () => setZoom(zoom + 0.15))
  selectElement('#zoom-out').addEventListener('click', () => setZoom(zoom - 0.15))
  selectElement('#map-fullscreen').addEventListener('click', () => {
    const active = selectElement('#map-panel').classList.toggle('fullscreen')
    document.body.classList.toggle('map-fullscreen', active)
    showToast(active ? 'Map expanded' : 'Map restored')
  })
  selectElement('#map-list-toggle').addEventListener('click', event => {
    const button = event.currentTarget as HTMLButtonElement
    const visible = mapEventList.hidden
    mapEventList.hidden = !visible
    button.setAttribute('aria-pressed', String(visible))
  })
  mapViewport.addEventListener('wheel', event => {
    event.preventDefault()
    setZoom(zoom + (event.deltaY < 0 ? 0.1 : -0.1), { x: event.clientX, y: event.clientY })
  }, { passive: false })
  mapViewport.addEventListener('pointerdown', event => {
    if (!isSpacePressed) return
    dragOrigin = { x: event.clientX, y: event.clientY, panX, panY }
    mapViewport.setPointerCapture(event.pointerId)
    mapViewport.classList.add('panning')
  })
  mapViewport.addEventListener('pointermove', event => {
    if (!dragOrigin) return
    panX = dragOrigin.panX + event.clientX - dragOrigin.x
    panY = dragOrigin.panY + event.clientY - dragOrigin.y
    updateMapTransform()
  })
  const endDrag = (): void => {
    dragOrigin = null
    mapViewport.classList.remove('panning')
  }
  mapViewport.addEventListener('pointerup', endDrag)
  mapViewport.addEventListener('pointercancel', endDrag)
  window.addEventListener('keydown', event => {
    const formTarget = event.target instanceof HTMLInputElement || event.target instanceof HTMLSelectElement
    if (event.code === 'Space' && !formTarget) {
      isSpacePressed = true
      mapViewport.classList.add('pan-ready')
      event.preventDefault()
    }
    if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === 'k') {
      event.preventDefault()
      globalSearch.focus()
    }
  })
  window.addEventListener('keyup', event => {
    if (event.code !== 'Space') return
    isSpacePressed = false
    endDrag()
    mapViewport.classList.remove('pan-ready')
  })
}

function renderPlaybackIcon(name: 'play' | 'pause'): void {
  playbackToggle.replaceChildren()
  const icon = makeElement('i')
  icon.dataset.lucide = name
  playbackToggle.append(icon)
  createIcons({ icons: iconSet, root: playbackToggle })
}

function stopPlayback(): void {
  if (playbackTimer !== null) window.clearInterval(playbackTimer)
  playbackTimer = null
  playbackToggle.classList.remove('playing')
  playbackToggle.setAttribute('aria-label', 'Play timeline')
  renderPlaybackIcon('play')
}

function startPlayback(): void {
  stopPlayback()
  playbackToggle.classList.add('playing')
  playbackToggle.setAttribute('aria-label', 'Pause timeline')
  renderPlaybackIcon('pause')
  const multiplier = Number.parseFloat(playbackSpeed.value)
  playbackTimer = window.setInterval(() => {
    if (selectedTimelineIndex >= timeline.length - 1) {
      stopPlayback()
      return
    }
    setTimelineIndex(selectedTimelineIndex + 1, true)
  }, 1500 / multiplier)
}

function bindTimeline(): void {
  playbackToggle.addEventListener('click', () => playbackTimer === null ? startPlayback() : stopPlayback())
  selectElement('#step-back').addEventListener('click', () => setTimelineIndex(selectedTimelineIndex - 1, true))
  selectElement('#step-forward').addEventListener('click', () => setTimelineIndex(selectedTimelineIndex + 1, true))
  playbackSpeed.addEventListener('change', () => {
    if (playbackTimer !== null) startPlayback()
  })
  timelineTrack.addEventListener('pointerdown', event => {
    if ((event.target as HTMLElement).closest('.timeline-event')) return
    const rect = timelineTrack.getBoundingClientRect()
    const ratio = Math.max(0, Math.min(1, (event.clientX - rect.left) / rect.width))
    setTimelineIndex(Math.round(ratio * (timeline.length - 1)), true)
  })
  timelineTrack.addEventListener('keydown', event => {
    if (event.key === 'ArrowLeft') setTimelineIndex(selectedTimelineIndex - 1, true)
    else if (event.key === 'ArrowRight') setTimelineIndex(selectedTimelineIndex + 1, true)
    else return
    event.preventDefault()
  })
}

function bindChrome(): void {
  selectElement('#sidebar-toggle').addEventListener('click', () => {
    const collapsed = sidebar.classList.toggle('collapsed')
    document.body.classList.toggle('sidebar-collapsed', collapsed)
    const button = selectElement<HTMLButtonElement>('#sidebar-toggle')
    button.setAttribute('aria-label', collapsed ? 'Expand navigation' : 'Collapse navigation')
  })
  document.querySelectorAll<HTMLButtonElement>('.nav-item').forEach(button => {
    button.addEventListener('click', () => {
      document.querySelectorAll('.nav-item').forEach(item => item.classList.remove('active'))
      button.classList.add('active')
      if (button.dataset.view !== 'incidents') showToast((button.textContent?.trim() ?? 'View') + ' view queued')
    })
  })
  document.querySelectorAll<HTMLButtonElement>('#log-tabs .tab').forEach(tab => {
    tab.addEventListener('click', () => {
      activeLogFilter = tab.dataset.logFilter as 'all' | LogKind
      document.querySelectorAll<HTMLButtonElement>('#log-tabs .tab').forEach(candidate => {
        const active = candidate === tab
        candidate.classList.toggle('active', active)
        candidate.setAttribute('aria-selected', String(active))
      })
      renderLogs()
    })
  })
  for (const selector of ['#date-start', '#date-end', '#time-range']) {
    selectElement(selector).addEventListener('change', () => showToast('Timeline range updated'))
  }
  selectElement('#live-status').addEventListener('click', event => {
    const button = event.currentTarget as HTMLButtonElement
    const connected = button.getAttribute('aria-pressed') === 'true'
    button.setAttribute('aria-pressed', String(!connected))
    button.classList.toggle('paused', connected)
    button.replaceChildren()
    const dot = makeElement('span', 'live-dot')
    button.append(dot, document.createTextNode(connected ? 'Paused' : 'Connected'))
  })
  selectElement('.top-actions .icon-button').addEventListener('click', () => showToast('3 new incident updates'))
  selectElement('.avatar').addEventListener('click', () => showToast('Signed in as Maya Chen · Incident Commander'))
  document.querySelectorAll<HTMLButtonElement>('[data-service]').forEach(button => {
    button.addEventListener('click', () => showToast((button.dataset.service ?? 'Service') + ' health details opened'))
  })
  selectElement('#simulation-toggle').addEventListener('click', () => {
    if (simulationTimer === null) {
      document.body.classList.add('simulation-mode')
      addSimulationEvent()
      simulationTimer = window.setInterval(addSimulationEvent, 5000)
      showToast('Simulation mode active')
    } else {
      window.clearInterval(simulationTimer)
      simulationTimer = null
      document.body.classList.remove('simulation-mode')
      showToast('Simulation mode stopped')
    }
  })
}

function addSimulationEvent(): void {
  const cities = ['Oslo', 'Toronto', 'Mumbai', 'Seoul', 'Madrid']
  const city = cities[Math.floor(Math.random() * cities.length)]
  const severity: Severity = Math.random() > 0.7 ? 'P1' : 'P2'
  const time = new Date().toISOString().slice(11, 19)
  const index = incidents.length + 1
  const incident: Incident = {
    id: 'SIM-' + String(index).padStart(4, '0'), city, country: 'Simulation',
    region: city === 'Toronto' ? 'North America' : city === 'Madrid' || city === 'Oslo' ? 'Europe' : 'Asia Pacific',
    regionCode: 'sim-region-' + index, severity, status: 'active',
    x: 18 + Math.random() * 68, y: 22 + Math.random() * 52,
    source: 'simulation-agent-' + index, protocol: 'HTTPS / 443', confidence: 88,
    title: 'Synthetic response drill', duration: '00:00:01', users: '0',
    impact: 'Simulation', owner: 'Maya Chen', initials: 'MC', timelineIndex: timeline.length,
    service: 'API Gateway'
  }
  incidents.push(incident)
  timeline.push({ time, title: severity + ' simulation signal', detail: 'Synthetic event injected near ' + city + '.', kind: 'alert', severity, incidentId: incident.id })
  selectedIncidentId = incident.id
  selectedTimelineIndex = timeline.length - 1
  renderTimeline()
  renderLogs()
}

function enableSimulationMode(): void {
  const params = new URLSearchParams(location.search)
  if (!params.has('simulation')) return
  selectElement<HTMLButtonElement>('#simulation-toggle').click()
}

function initialize(): void {
  createIcons({ icons: iconSet, attrs: { 'stroke-width': 1.75 } })
  bindFilters()
  bindMap()
  bindTimeline()
  bindChrome()
  renderMarkers()
  renderLocations()
  renderTimeline()
  renderIncident()
  renderLogs()
  updateMapTransform()
  enableSimulationMode()
}

window.addEventListener('beforeunload', () => {
  if (playbackTimer !== null) window.clearInterval(playbackTimer)
  if (simulationTimer !== null) window.clearInterval(simulationTimer)
})

window.editor.onMenu(event => {
  if (event === 'persist-session') void window.editor.sessionFlushed()
})

initialize()
