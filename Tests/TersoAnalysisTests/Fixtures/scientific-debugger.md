# 🧪 Collider analysis

We use $r_T$ to compare the recoil distributions.

Let $r_T$ denote the transverse recoil ratio. We define $m_H$ as the Higgs-boson mass.
The fit uses $m_H = 125.25 \pm 0.17\,\mathrm{GeV}$ from \cite{atlas2024}.

## Method

We compute the acceptance using simulated events.
In practice, I find this choice more useful.

\begin{equation}
A = \frac{r_T}{m_H} \label{eq:acceptance}
\end{equation}

Equation \eqref{eq:acceptance} uses the recoil ratio. See \ref{fig:spectrum}, \ref{tab:inputs} and \ref{sec:results}.

\begin{figure}
\includegraphics{spectrum.pdf}
\caption{The observed recoil spectrum.}
\label{fig:spectrum}
\end{figure}

\begin{table}
\caption{Fit inputs.}
\label{tab:inputs}
\end{table}

## Results
\label{sec:results}

This proves the approximation.

The uncertainty is smaller; see \eqref{eq:missing}.

\begin{equation}
r_T = 1 \label{eq:acceptance}
\end{equation}

The process is $a \to b \Rightarrow c$, with $\sin x$, $\max y$ and $\operatorname{Tr} M$.

\begin{thebibliography}{9}
\bibitem{atlas2024} ATLAS Collaboration. Higgs mass measurement.
\end{thebibliography}
