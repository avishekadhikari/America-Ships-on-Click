import React from 'react';
import { followTabLink } from '../lib/routes';

interface NotFoundProps {
  setActiveTab: (tab: string) => void;
}

export const NotFound: React.FC<NotFoundProps> = ({ setActiveTab }) => {
  return (
    <section className="mx-auto flex max-w-xl flex-col items-start px-6 py-20">
      <p className="eyebrow">404</p>
      <h1 className="mt-2 text-5xl font-black tracking-tighter">Page not found</h1>
      <p className="mt-4 max-w-md text-lg leading-snug">
        That address is not on the board. The load board and the open books are still here.
      </p>
      <a
        href="/"
        className="btn primary mt-8 py-3.5 px-6"
        onClick={(e) => followTabLink(e, setActiveTab, 'home')}
      >
        Back to the board
      </a>
    </section>
  );
};
