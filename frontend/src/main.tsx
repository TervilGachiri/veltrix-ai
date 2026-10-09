import ToolsDock from './ToolsDock';
import TeamWorkspace from './TeamWorkspace';
import StreamingChat from './StreamingChat';
import DocumentAssistant from './DocumentAssistant';
import React from 'react';
import ReactDOM from 'react-dom/client';
import App from './App';
import './styles.css';
ReactDOM.createRoot(document.getElementById('root')!).render(<React.StrictMode><><><App /><ToolsDock /><TeamWorkspace /><StreamingChat /></><DocumentAssistant /></></React.StrictMode>);
