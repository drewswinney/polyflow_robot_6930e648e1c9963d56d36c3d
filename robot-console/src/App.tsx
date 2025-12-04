import { useState } from "react";
import { Button, Card, Variant } from "@polyflowrobotics/ui-components";
import Logo from "./components/Logo";
import { FontAwesomeIcon } from "@fortawesome/react-fontawesome";
import {
  faTerminal,
  faWifi,
  faRightFromBracket,
  faRobot,
} from "@fortawesome/free-solid-svg-icons";
import { ConnectionPage } from "./pages/Connection";
import { GeneralPage } from "./pages/General";
import { LogPage } from "./pages/Logs";
import { Page, Pages } from "./types/page";

const PageInformation = new Map<Pages, Page>([
  [
    Pages.General,
    {
      title: "General",
      description: "General robot information and settings",
    },
  ],
  [
    Pages.Connection,
    {
      title: "Connection Settings",
      description: "Connect to Wifi and Bluetooth devices",
    },
  ],
  [
    Pages.Logs,
    {
      title: "Logs",
      description: "ROS and Service Logs",
    },
  ],
]);

export default function App() {
  const [sidebarOpen, setSidebarOpen] = useState(false);
  const [currentPage, setCurrentPage] = useState<Pages>(Pages.Connection);

  return (
    <div className="app-shell theme-light">
      <main className="content">
        {sidebarOpen && (
          <div
            className="sidebar-overlay"
            onClick={() => setSidebarOpen(false)}
            aria-label="Close sidebar overlay"
          />
        )}
        <aside className={`sidebar ${sidebarOpen ? "is-open" : ""}`}>
          <div className="branding">
            <Logo />
            <span className="title">Polyflow Robot Console</span>
          </div>
          <div className="header">Pages</div>
          <nav className="nav">
            <Button
              className="nav-item"
              onPress={() => {
                setCurrentPage(Pages.General);
                setSidebarOpen(false);
              }}
              variant={Variant.Transparent}
              selected={currentPage == Pages.General}
            >
              <FontAwesomeIcon icon={faRobot} />
              <span>General</span>
            </Button>
            <Button
              className="nav-item"
              onPress={() => {
                setCurrentPage(Pages.Connection);
                setSidebarOpen(false);
              }}
              variant={Variant.Transparent}
              selected={currentPage == Pages.Connection}
            >
              <FontAwesomeIcon icon={faWifi} />
              <span>Connection</span>
            </Button>
            <Button
              className="nav-item"
              onPress={() => {
                setCurrentPage(Pages.Logs);
                setSidebarOpen(false);
              }}
              variant={Variant.Transparent}
              selected={currentPage == Pages.Logs}
            >
              <FontAwesomeIcon icon={faTerminal} />
              <span>Logs</span>
            </Button>
          </nav>
        </aside>
        <Card className="page">
          <div className="page-header">
            <Button
              className="sidebar-toggle"
              variant={Variant.Transparent}
              onClick={() => setSidebarOpen(true)}
              aria-label="Open navigation"
            >
              <FontAwesomeIcon icon={faRightFromBracket} />
            </Button>
            <div className="title">
              <h5>{PageInformation.get(currentPage)?.title}</h5>
              <span>{PageInformation.get(currentPage)?.description}</span>
            </div>
          </div>
          {currentPage == Pages.General && <GeneralPage />}
          {currentPage == Pages.Connection && <ConnectionPage />}
          {currentPage == Pages.Logs && <LogPage />}
        </Card>
      </main>
    </div>
  );
}
