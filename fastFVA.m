function [minFlux,maxFlux,optsol,ret,fbasol,fvamin,fvamax] = fastFVA(model,optPercentage,objective,solver,rxnsList,matrixAS,cpxControl,cpxAlgorithm,strategy,rxnsOptMode)
%fastFVA Flux variablity analysis optimized for the GLPK and CPLEX solvers.
%
% [minFlux,maxFlux] = fastFVA(model,optPercentage,objective, solver)
%
% Solves LPs of the form for all v_j: max/min v_j
%                                     subject to S*v = b
%                                     lb <= v <= ub
% Inputs:
%   model             Model structure
%     Required fields
%       S            Stoichiometric matrix
%       b            Right hand side = 0
%       c            Objective coefficients
%       lb           Lower bounds
%       ub           Upper bounds
%     Optional fields
%       A            General constraint matrix
%       csense       Type of constraints, csense is a vector with elements
%                    'E' (equal), 'L' (less than) or 'G' (greater than).
%     If the optional fields are supplied, following LPs are solved
%                    max/min v_j
%                    subject to Av {'<=' | '=' | '>='} b
%                                lb <= v <= ub
%
%   optPercentage    Only consider solutions that give you at least a certain
%                    percentage of the optimal solution (default = 100
%                    or optimal solutions only)
%   objective        Objective ('min' or 'max') (default 'max')
%   solver           'cplex'
%   matrixAS         'A' or 'S' - choice of the model matrix, coupled (A) or uncoupled (S)
%   cpxControl       Parameter set of CPLEX loaded externally
%   cpxAlgorithm     Choice of the solution algorithm within CPLEX
%   rxnsList         List of reactions to analyze (default all rxns, i.e. 1:length(model.rxns))
%   rxnsOptMode      List of min/max optimizations to perform:
%                    0 = only minimization;
%                    1 = only maximization;
%                    2 = minimization & maximization;
%
% Outputs:
%   minFlux   Minimum flux for each reaction
%   maxFlux   Maximum flux for each reaction
%   optsol    Optimal solution (of the initial FBA)
%   ret       Zero if success
%   fbasol    Initial FBA in FBASOL
%   fvamin    matrix with flux values for the minimization problem
%   fvamax    matrix with flux values for the maximization problem
%
% [minFlux,maxFlux,optsol,ret,fbasol,fvamin,fvamax] = fastFVA(...) returns
% vectors for the initial FBA in FBASOL together with matrices FVAMIN and
% FVAMAX containing the flux values for each individual min/max problem.
% Note that for large models the memory requirements may become prohibitive.
% To save large fvamin and fvamax matrices please toggle v7.3 in Preferences -> General -> MAT-Files
%
% If a rxnsList vector is specified then only the corresponding entries in
% minFlux and maxFlux are defined (all remaining entries are zero).
%
% Example:
%    load modelRecon1Biomass.mat % Human reconstruction network (Recon1)
%    SetWorkerCount(4) % Only if you have the parallel toolbox installed
%    [minFlux,maxFlux] = fastFVA(model, 90);
%
% Reference: S. Gudmundsson and I. Thiele, Computationally efficient
%            Flux Variability Analysis. BMC Bioinformatics, 2010, 11:489

% Author: Steinn Gudmundsson.
% Contributor: Laurent Heirendt, LCSB - Linux verison
% Last updated: April/May 2016

% SPLITTING STRATEGIES

% (0) Blind-splitting : DEFAULT
%
% (1) Extremal Hard-and-Easy Blocks Splitting
% everyone gets a heavy chunk and everyone gets and easy chunk
% ----
% (2) Central Hard-and-Easy Blocks Splitting
% the first one gets one bad and one very easy
% the last one get a hard on and one very easy
% ----
% (3) Extremal Hard-and-Easy Points
% every thread gets the worst, until nothing else is left


% Turn on the load balancing for large problems
loadBalancing = 0; %0: off; 1: on

% Define if information about the work load distriibution will be shown or not
showSplitting = 1;

% Turn on the verbose mode
verbose=1;

% Define the input arguments

if (nargin<9 || isempty(strategy)), strategy       = 0;          end
if (nargin<8 || isempty(cpxAlgorithm)), cpxAlgorithm   = 0;          end
if (nargin<7 || isempty(cpxControl)) , cpxControl   = struct([]); end
if (nargin<6 || isempty(matrixAS)) , matrixAS       = 'S';        end
if (nargin<5 || isempty(rxnsList))
    rxns = 1:length(model.rxns);
    rxnsList = {};
else

    %% check here if the vector of rxns is sorted or not
    % this needs to be fixed to sort the flux vectors accordingly
    % as the find() function sorts the reactions automatically
    [~,indexRxns]=ismember(model.rxns, rxnsList) ;
    nonZeroIndices = [];
    for i=1:length(indexRxns)
      if(indexRxns(i) ~= 0) nonZeroIndices = [nonZeroIndices, indexRxns(i)]; end
    end
    if issorted(nonZeroIndices) == 0
      fprintf('\n-- Warning:: Your input reaction vector is not sorted. Please sort your vector first.\n\n')
    end

    rxns = find(ismember(model.rxns, rxnsList))';%transpose rxns

end
if (nargin<4 || isempty(solver)), solver         = 'cplex';     end
if (nargin<3 || isempty(objective)), objective      = 'max';      end
if (nargin<2 || isempty(optPercentage)), optPercentage  = 100;        end
if (nargin<10 || isempty(rxnsOptMode))
    rxnsOptMode = 2*ones(length(rxns),1)'; %status = 2 (min & max) for all reactions
end

% Define extra outputs if required
if nargout>4
   assert(nargout == 7);
   bExtraOutputs=true;
else
   bExtraOutputs=false;
end

% Define the objective
if strcmpi(objective,'max')
   obj=-1;
elseif strcmpi(objective,'min')
   obj=1;
else
   error('Unknown objective')
end;

% Define the solver
if strmatch('glpk',solver)
   %FVAc=@glpkFVAcc;
   fprintf('ERROR : GLPK is not supported.')
elseif strmatch('cplex',solver)
   FVAc=@cplexFVAnew;
else
   error(sprintf('Solver %s not supported', solver))
end;

% Define the CPLEX parameter set and the associated values - split the struct
namesCPLEXparams    = fieldnames(cpxControl);
nCPLEXparams        = length(namesCPLEXparams);
valuesCPLEXparams   = zeros(nCPLEXparams,1);
for i =1:nCPLEXparams
  valuesCPLEXparams(i) = getfield(cpxControl, namesCPLEXparams{i});
end

% Retrieve the b vector of the model file
b = model.b;

% Define the stoichiometric matrix to be solved
if isfield(model,'A') && (matrixAS == 'A')
   % "Generalized FBA"
   A = model.A;
   csense = model.csense(:);
   fprintf(' >> Solving Model.A. (coupled) - Generalized\n');
else
   % Standard FBA
   A = model.S;
   csense = char('E'*ones(size(A,1),1));
   b = b(1:size(A,1));
   fprintf(' >> Solving Model.S. (uncoupled) \n');
end

fprintf(' >> The number of arguments is: input: %d, output %d.\n', nargin, nargout);

% Define the matrix A as sparse in case it is not
if ~issparse(A)
   A = sparse(A); % C code assumes a sparse stochiometric matrix
end

% Determine the size of the stoichiometric matrix
[m,n] = size(A);
fprintf(' >> Size of stoichiometric matrix: (%d,%d)\n', m,n);

% Determine the number of reactions that are considered
nR = length(rxns);
if nR ~= n
  fprintf(' >> Only %d reactions of %d are solved (~ %1.2f%%).\n', nR, n, nR*100/n);
  n = nR;
else
  fprintf(' >> All the %d reactions are solved.\n', n);
end

% output how many reactions are min, max, or both
totalOptMode = length(find(rxnsOptMode == 0));
if(totalOptMode == 1)
    fprintf(' >> %d reaction out of %d is minimized (%1.2f%%).\n', totalOptMode , n, totalOptMode*100/n);
else
    fprintf(' >> %d reactions out of %d are minimized (%1.2f%%).\n', totalOptMode , n, totalOptMode*100/n);
end

totalOptMode = length(find(rxnsOptMode == 1));
if(totalOptMode == 1)
    fprintf(' >> %d reaction out of %d is maximized (%1.2f%%).\n', totalOptMode , n, totalOptMode*100/n);
else
    fprintf(' >> %d reactions out of %d are maximized (%1.2f%%).\n', totalOptMode , n, totalOptMode*100/n);
end

totalOptMode = length(find(rxnsOptMode == 2));
if(totalOptMode == 1)
    fprintf(' >> %d reaction out of %d is minimized and maximized (%1.2f%%).\n', totalOptMode , n, totalOptMode*100/n);
else
    fprintf(' >> %d reactions out of %d are minimized and maximized (%1.2f%%).\n', totalOptMode , n, totalOptMode*100/n);
end

% Create a MATLAB parallel pool
poolobj = gcp('nocreate'); % If no pool, do not create new one.
if isempty(poolobj)
    nworkers = 0;
else
    nworkers = poolobj.NumWorkers;
end;

% Launch fastFVA on 1 core
if nworkers<=1
   % Sequential version
   fprintf(' \n WARNING: The Sequential Version might take a long time.\n\n');
   if bExtraOutputs
       [minFlux,maxFlux,optsol,ret,fbasol,fvamin,fvamax]=FVAc(model.c,A,b,csense,model.lb,model.ub, ...
                                                              optPercentage,obj,(1:n)', ...
                                                              1, cpxControl, valuesCPLEXparams, cpxAlgorithm,rxnsOptMode);
   else
       [minFlux,maxFlux,optsol,ret]=FVAc(model.c,A,b,csense,model.lb,model.ub, ...
                                         optPercentage,obj,(1:n)', ...
                                         1, cpxControl, valuesCPLEXparams, cpxAlgorithm,rxnsOptMode);
   end

   if ret ~= 0 && verbose
      fprintf('Unable to complete the FVA, return code=%d\n', ret);
   end;
else
   % Divide the reactions amongst workers
   %
   % The load balancing can be improved for certain problems, e.g. in case
   % of problems involving E-type matrices, some workers will get mostly
   % well-behaved LPs while others may get many badly scaled LPs.

   if n > 5000 & loadBalancing == 1
      % A primitive load-balancing strategy for large problems
      nworkers = 4*nworkers;
      fprintf(' >> The load is balanced and the number of virtual workers is %d.\n', nworkers);
   end

   nrxn=repmat(fix(n/nworkers),nworkers,1);
   i=1;
   while sum(nrxn) < n
      nrxn(i)=nrxn(i)+1;
      i=i+1;
   end

     Nrxns = length(model.rxns);
     assert(sum(nrxn)==n);
     istart=1; iend=nrxn(1);
     for i=2:nworkers
        istart(i)=iend(i-1)+1;
        iend(i)=istart(i)+nrxn(i)-1;
     end

   startMarker1 = istart;
   endMarker1 = iend;

   startMarker2 = istart;
   endMarker2 = iend;


%% Calculate the column density and row density
   [Nmets,Nrxns] = size(A);

   cdVect = zeros(Nrxns,1);
   rdVect = zeros(Nmets,1);

   for i=1:Nmets
     rowDensity = nnz(A(i,:));
     rowDensity = rowDensity / Nrxns * 100;
     rdVect(i) = rowDensity;
   end;

   for i=1:Nrxns
     columnDensity = nnz(A(:,i));
     columnDensity = columnDensity / Nmets * 100;
     cdVect(i) = columnDensity;
   end;


   [sortedcdVect,indexcdVect] = sort(cdVect,'descend');
   [sortedrdVect,indexrdVect] = sort(rdVect,'descend');

   rxnsVect = linspace(1,Nrxns,Nrxns);
   metsVect = linspace(1,Nmets,Nmets);

   sortedrxnsVect = rxnsVect(indexcdVect);
   sortedmetsVect = metsVect(indexrdVect);

   if(strategy == 1)

       nbRxnsPerThread = ceil(Nrxns/(2*nworkers));

       for i = 1:nworkers
         startMarker1(i) = (i-1) * nbRxnsPerThread + 1;
         endMarker1(i) = i * nbRxnsPerThread;

         startMarker2(i) = startMarker1(i) + ceil(Nrxns/2);
         endMarker2(i) = endMarker1(i) + ceil(Nrxns/2);

           if endMarker1(i) > Nrxns
             endMarker1(i) = Nrxns;
           end;

           if endMarker2(i) > Nrxns
             endMarker2(i) = Nrxns;
           end;
       end;
    elseif(strategy == 2)
      nbRxnsPerThread = ceil(Nrxns/(2*nworkers));

      for i = 1:nworkers
        startMarker1(i) = (i-1) * nbRxnsPerThread + 1;
        endMarker1(i) = i * nbRxnsPerThread;

        endMarker2(i) = Nrxns - startMarker1(i) - 1;
        startMarker2(i) = Nrxns - endMarker1(i);

          if endMarker1(i) > Nrxns
            endMarker1(i) = Nrxns;
          end;

          if endMarker2(i) > Nrxns
            endMarker2(i) = Nrxns;
          end;
      end;
   end;

   minFlux = zeros(length(model.rxns),1);
   maxFlux = zeros(length(model.rxns),1);
   iopt    = zeros(nworkers,1);
   iret    = zeros(nworkers,1);

   % Initialilze extra outputs
   if bExtraOutputs
      fvaminRes={};
      fvamaxRes={};
      fbasolRes={};
   end

   fprintf('\n -- Starting to loop through the %d workers. -- \n', nworkers);
   fprintf('\n -- The splitting strategy is %d. -- \n', strategy);

   out = parfor_progress(nworkers);

   parfor i = 1:nworkers

     rxnsKey = 0; %silence warning

     %preparation of reactionKey
      if strategy == 1 || strategy == 2
        rxnsKey = [sortedrxnsVect(startMarker1(i):endMarker1(i)), sortedrxnsVect(startMarker2(i):endMarker2(i))];
      else
        rxnsKey = istart(i):iend(i);
      end

      t = getCurrentTask();

      if(strategy == 0)
      fprintf('\n----------------------------------------------------------------------------------\n');
      fprintf('--  Task Launched // TaskID: %d / %d (LoopID = %d) <> [%d, %d] / [%d, %d].\n', ...
              t.ID, nworkers, i, istart(i), iend(i), m, n);
      end;

      tstart = tic;

      fvamin_single = 0; fvamax_single = 0; fbasol_single=0; % silence warnings

      %%determine the reaction density here

      if bExtraOutputs
          [minf,maxf,iopt(i),iret(i),fbasol_single,fvamin_single,fvamax_single] = FVAc(model.c,A,b,csense,model.lb,model.ub, ...
                                           optPercentage,obj, rxnsKey', ...
                                           t.ID, cpxControl, valuesCPLEXparams, cpxAlgorithm,rxnsOptMode);
      else
      if(strategy == 0)
          fprintf(' >> Number of reactions given to the worker: %d \n', length((istart(i):iend(i)) ) );
      end;

          [minf,maxf,iopt(i),iret(i)] = FVAc(model.c,A,b,csense,model.lb,model.ub, ...
                                         optPercentage,obj, rxnsKey', ...
                                         t.ID, cpxControl, valuesCPLEXparams, cpxAlgorithm,rxnsOptMode);
      end

      fprintf(' >> Time spent in FVAc: %1.1f seconds.', toc(tstart));

      if iret(i) ~= 0 && verbose
         fprintf('Problems solving partition %d, return code=%d\n', i, iret(i))
      end

      minFlux=minFlux+minf;
      maxFlux=maxFlux+maxf;

      if bExtraOutputs
         fvaminRes{i}=fvamin_single;
         fvamaxRes{i}=fvamax_single;
         fbasolRes{i}=fbasol_single;
      end

      fprintf('\n----------------------------------------------------------------------------------\n');

      % print out the percentage of the progress
      percout =   parfor_progress;

      if(percout < 100)
        fprintf(' ==> %1.1f%% done. Please wait ...\n', percout);
      else
        fprintf(' ==> 100%% done. Analysis completed.\n', percout);
      end

   end;

   for i =1:length(iret)
     fprintf(' >> iRet( %i ) = %1.1f << \n', i, iret(i));
   end

   % Aggregate results
   optsol=iopt(1);
   ret=max(iret);

   out = parfor_progress(0);

end


if bExtraOutputs
  if nworkers > 1
      fbasol = fbasolRes{1}; % Initial FBA solutions are identical across workers
  end

  fvamin = zeros(length(model.rxns),length(model.rxns));
  fvamax = zeros(length(model.rxns),length(model.rxns));

  if(strategy == 0)
    for i=1:nworkers
      fvamin(:,rxns(istart(i):iend(i)))=fvaminRes{i};
      fvamax(:,rxns(istart(i):iend(i)))=fvamaxRes{i};
    end;
  end
end

if(strategy == 0 && ~ isempty(rxnsList))
    if bExtraOutputs
        fvamin = fvamin(:,rxns);%keep only nonzero columns
        fvamax = fvamax(:,rxns);
    end
    minFlux(find(~ismember(model.rxns, rxnsList)))=[];
    maxFlux(find(~ismember(model.rxns, rxnsList)))=[];
end;
