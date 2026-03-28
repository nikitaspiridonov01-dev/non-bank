import { Redirect, Route } from 'react-router-dom';
import { IonApp, IonButton, IonRouterOutlet, IonTabs, IonTabBar, IonTabButton, IonIcon, IonLabel, setupIonicReact } from '@ionic/react';
import { IonReactRouter } from '@ionic/react-router';
import { addOutline, home, settingsOutline } from 'ionicons/icons';
import Home from './pages/Home';
import Settings from './pages/Settings';
import { TransactionsProvider } from './context/TransactionsContext';
import CreateTransactionModal from './components/CreateTransactionModal';

/* Core CSS required for Ionic components to work properly */
import '@ionic/react/css/core.css';

/* Basic CSS for apps built with Ionic */
import '@ionic/react/css/normalize.css';
import '@ionic/react/css/structure.css';
import '@ionic/react/css/typography.css';

/* Optional CSS utils that can be commented out */
import '@ionic/react/css/padding.css';
import '@ionic/react/css/float-elements.css';
import '@ionic/react/css/text-alignment.css';
import '@ionic/react/css/text-transformation.css';
import '@ionic/react/css/flex-utils.css';
import '@ionic/react/css/display.css';

/**
 * Ionic Dark Mode
 * -----------------------------------------------------
 * For more info, please see:
 * https://ionicframework.com/docs/theming/dark-mode
 */

/* import '@ionic/react/css/palettes/dark.always.css'; */
/* import '@ionic/react/css/palettes/dark.class.css'; */
import '@ionic/react/css/palettes/dark.always.css';

/* Theme variables */
import './theme/variables.css';
import './App.css';
import { useEffect, useState } from 'react';

setupIonicReact({
  mode: 'ios'
});

export default function App() {
  const [darkMode, setDarkMode] = useState<boolean>(true);
  const [isCreateTransactionOpen, setIsCreateTransactionOpen] = useState(false);

  useEffect(() => {
    const saved = localStorage.getItem('darkMode');
    const prefersDark = window.matchMedia('(prefers-color-scheme: dark)').matches;
    const isDark = saved ? saved === 'true' : prefersDark;
    setDarkMode(isDark);
    document.documentElement.classList.toggle('ion-palette-dark', isDark);
  }, []);

  const toggleDarkMode = () => {
    const newDarkMode = !darkMode;
    setDarkMode(newDarkMode);
    document.documentElement.classList.toggle('ion-palette-dark', newDarkMode);
    localStorage.setItem('darkMode', newDarkMode.toString());
  };

  return (
    <IonApp>
      <TransactionsProvider>
      <IonButton onClick={toggleDarkMode}>
        {darkMode ? 'Light Mode' : 'Dark Mode'}
      </IonButton>
      <IonReactRouter>
        <IonTabs>
          <IonRouterOutlet>
            <Route exact path="/home">
              <Home />
            </Route>
            <Route exact path="/settings">
              <Settings />
            </Route>
            <Route exact path="/">
              <Redirect to="/home" />
            </Route>
          </IonRouterOutlet>
          <IonTabBar slot="bottom" className="app-tab-bar">
            <IonTabButton tab="home" href="/home">
              <IonIcon icon={home} />
              <IonLabel>Home</IonLabel>
            </IonTabButton>
            <IonTabButton tab="settings" href="/settings">
              <IonIcon icon={settingsOutline} />
              <IonLabel>Settings</IonLabel>
            </IonTabButton>
          </IonTabBar>
        </IonTabs>
      </IonReactRouter>
      <button
        className="app-create-tab"
        onClick={() => setIsCreateTransactionOpen(true)}
        aria-label="Create transaction"
        type="button"
      >
        <span className="app-create-tab-badge">
          <IonIcon icon={addOutline} />
        </span>
        <span className="app-create-tab-label">New record</span>
      </button>
      <CreateTransactionModal
        isOpen={isCreateTransactionOpen}
        onClose={() => setIsCreateTransactionOpen(false)}
      />
      </TransactionsProvider>
    </IonApp>
  );
}
